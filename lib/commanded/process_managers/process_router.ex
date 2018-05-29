defmodule Commanded.ProcessManagers.ProcessRouter do
  @moduledoc false

  use GenServer
  use Commanded.Registration

  require Logger

  alias Commanded.ProcessManagers.{
    ProcessManagerInstance,
    ProcessRouter,
    Supervisor
  }

  alias Commanded.EventStore
  alias Commanded.EventStore.RecordedEvent
  alias Commanded.Subscriptions

  defmodule State do
    @moduledoc false

    defstruct command_dispatcher: nil,
              consistency: nil,
              process_manager_name: nil,
              process_manager_module: nil,
              subscribe_from: nil,
              process_managers: %{},
              supervisor: nil,
              subscription: nil,
              last_seen_event: nil,
              pending_acks: %{},
              pending_events: []
  end

  def start_link(process_manager_name, process_manager_module, command_dispatcher, opts \\ []) do
    name = {ProcessRouter, process_manager_name}

    state = %State{
      process_manager_name: process_manager_name,
      process_manager_module: process_manager_module,
      command_dispatcher: command_dispatcher,
      consistency: opts[:consistency] || :eventual,
      subscribe_from: opts[:start_from] || :origin
    }

    Registration.start_link(name, __MODULE__, state)
  end

  def init(%State{} = state) do
    :ok = GenServer.cast(self(), :subscribe_to_events)

    {:ok, state}
  end

  @doc """
  Acknowledge successful handling of the given event by a process manager instance
  """
  def ack_event(process_router, %RecordedEvent{} = event, instance) do
    GenServer.cast(process_router, {:ack_event, event, instance})
  end

  @doc """
  Fetch the pid of an individual process manager instance identified by the
  given `process_uuid`
  """
  def process_instance(process_router, process_uuid) do
    GenServer.call(process_router, {:process_instance, process_uuid})
  end

  @doc """
  Fetch the `process_uuid` and pid of all process manager instances
  """
  def process_instances(process_router) do
    GenServer.call(process_router, :process_instances)
  end

  def handle_call(:process_instances, _from, %State{} = state) do
    %State{process_managers: process_managers} = state

    reply = Enum.map(process_managers, fn {process_uuid, pid} -> {process_uuid, pid} end)

    {:reply, reply, state}
  end

  def handle_call({:process_instance, process_uuid}, _from, %State{} = state) do
    %State{process_managers: process_managers} = state

    reply =
      case Map.get(process_managers, process_uuid) do
        nil -> {:error, :process_manager_not_found}
        process_manager -> process_manager
      end

    {:reply, reply, state}
  end

  def handle_cast({:ack_event, event, instance}, %State{} = state) do
    %State{pending_acks: pending_acks} = state
    %RecordedEvent{event_number: event_number} = event

    state =
      case pending_acks |> Map.get(event_number, []) |> List.delete(instance) do
        [] ->
          # Enqueue a message to continue processing any pending events
          GenServer.cast(self(), :process_pending_events)

          state = %State{state | pending_acks: Map.delete(pending_acks, event_number)}

          # no pending acks so confirm receipt of event
          confirm_receipt(event, state)

        pending ->
          # pending acks, don't ack event but wait for outstanding instances
          %State{state | pending_acks: Map.put(pending_acks, event_number, pending)}
      end

    {:noreply, state}
  end

  @doc """
  Subscribe the process router to all events
  """
  def handle_cast(:subscribe_to_events, %State{} = state) do
    {:noreply, subscribe_to_all_streams(state)}
  end

  def handle_cast(:process_pending_events, %State{pending_events: []} = state),
    do: {:noreply, state}

  def handle_cast(
        :process_pending_events,
        %State{pending_events: [event | pending_events]} = state
      ) do
    case length(pending_events) do
      0 ->
        :ok

      1 ->
        Logger.debug(fn -> describe(state) <> " has 1 pending event to process" end)

      count ->
        Logger.debug(fn -> describe(state) <> " has #{count} pending events to process" end)
    end

    state = handle_event(event, state)

    {:noreply, %State{state | pending_events: pending_events}}
  end

  @doc false
  # Subscription to event store has successfully subscribed, init process router
  def handle_info({:subscribed, subscription}, %State{subscription: subscription} = state) do
    Logger.debug(fn -> describe(state) <> " has successfully subscribed to event store" end)

    %State{command_dispatcher: command_dispatcher} = state

    {:ok, supervisor} = Supervisor.start_link(command_dispatcher)

    {:noreply, %State{state | supervisor: supervisor}}
  end

  def handle_info({:events, events}, %State{pending_events: pending_events} = state) do
    Logger.debug(fn -> describe(state) <> " received #{length(events)} event(s)" end)

    unseen_events = Enum.reject(events, &event_already_seen?(&1, state))

    state =
      case {pending_events, unseen_events} do
        {[], []} ->
          # no pending or unseen events, so state is unmodified
          state

        {[], _} ->
          # no pending events, but some unseen events so start processing them
          GenServer.cast(self(), :process_pending_events)

          %State{state | pending_events: unseen_events}

        {_, _} ->
          # already processing pending events, append the unseen events so they are processed afterwards
          %State{state | pending_events: pending_events ++ unseen_events}
      end

    {:noreply, state}
  end

  # remove a process manager instance that has stopped with a normal exit reason
  def handle_info(
        {:DOWN, _ref, :process, pid, :normal},
        %State{process_managers: process_managers} = state
      ) do
    {:noreply, %State{state | process_managers: remove_process_manager(process_managers, pid)}}
  end

  # stop process router when a process manager instance terminates abnormally
  def handle_info({:DOWN, _ref, :process, _pid, reason}, %State{} = state) do
    Logger.warn(fn -> describe(state) <> " is stopping due to: #{inspect(reason)}" end)
    {:stop, reason, state}
  end

  defp subscribe_to_all_streams(
         %State{
           consistency: consistency,
           process_manager_name: process_manager_name,
           subscribe_from: subscribe_from
         } = state
       ) do
    {:ok, subscription} =
      EventStore.subscribe_to_all_streams(process_manager_name, self(), subscribe_from)

    # register this event handler as a subscription with the given consistency
    :ok = Subscriptions.register(process_manager_name, consistency)

    %State{state | subscription: subscription}
  end

  # ignore already seen event
  defp event_already_seen?(%RecordedEvent{event_number: event_number}, %State{
         last_seen_event: last_seen_event
       }) do
    not is_nil(last_seen_event) and event_number <= last_seen_event
  end

  defp handle_event(%RecordedEvent{} = event, %State{} = state) do
    %RecordedEvent{
      event_number: event_number,
      data: data,
      stream_id: stream_id,
      stream_version: stream_version
    } = event

    %State{process_manager_module: process_manager_module} = state

    case process_manager_module.interested?(data) do
      {:start, process_uuid} ->
        Logger.debug(fn ->
          describe(state) <>
            " is interested in event: #{inspect(event_number)} (#{inspect(stream_id)}@#{
              inspect(stream_version)
            })"
        end)

        process_uuid
        |> List.wrap()
        |> Enum.reduce(state, fn process_uuid, state ->
          {process_instance, state} = start_process_manager(process_uuid, state)

          delegate_event(process_instance, event, state)
        end)

      {:continue, process_uuid} ->
        Logger.debug(fn ->
          describe(state) <>
            " is interested in event: #{inspect(event_number)} (#{inspect(stream_id)}@#{
              inspect(stream_version)
            })"
        end)

        process_uuid
        |> List.wrap()
        |> Enum.reduce(state, fn process_uuid, state ->
          {process_instance, state} = continue_process_manager(process_uuid, state)

          delegate_event(process_instance, event, state)
        end)

      {:stop, process_uuid} ->
        Logger.debug(fn ->
          describe(state) <>
            " has been stopped by event: #{inspect(event_number)} (#{inspect(stream_id)}@#{
              inspect(stream_version)
            })"
        end)

        state =
          process_uuid
          |> List.wrap()
          |> Enum.reduce(state, &stop_process_manager/2)

        ack_and_continue(event, state)

      false ->
        Logger.debug(fn ->
          describe(state) <>
            " is not interested in event: #{inspect(event_number)} (#{inspect(stream_id)}@#{
              inspect(stream_version)
            })"
        end)

        ack_and_continue(event, state)
    end
  end

  # continue processing any pending events and confirm receipt of the given event id
  defp ack_and_continue(%RecordedEvent{} = event, %State{} = state) do
    GenServer.cast(self(), :process_pending_events)

    confirm_receipt(event, state)
  end

  # confirm receipt of given event
  defp confirm_receipt(%RecordedEvent{event_number: event_number} = event, %State{} = state) do
    Logger.debug(fn ->
      describe(state) <> " confirming receipt of event: #{inspect(event_number)}"
    end)

    do_ack_event(event, state)

    %State{state | last_seen_event: event_number}
  end

  defp start_process_manager(process_uuid, %State{} = state) do
    %State{
      process_managers: process_managers,
      process_manager_name: process_manager_name,
      process_manager_module: process_manager_module,
      supervisor: supervisor
    } = state

    {:ok, process_manager} =
      Supervisor.start_process_manager(
        supervisor,
        process_manager_name,
        process_manager_module,
        process_uuid
      )

    Process.monitor(process_manager)

    state = %State{
      state
      | process_managers: Map.put(process_managers, process_uuid, process_manager)
    }

    {process_manager, state}
  end

  defp continue_process_manager(process_uuid, %State{} = state) do
    %State{process_managers: process_managers} = state

    case Map.get(process_managers, process_uuid) do
      nil ->
        start_process_manager(process_uuid, state)

      process_manager ->
        {process_manager, state}
    end
  end

  defp stop_process_manager(process_uuid, %State{} = state) do
    %State{process_managers: process_managers} = state

    case Map.get(process_managers, process_uuid) do
      nil ->
        state

      process_manager ->
        :ok = ProcessManagerInstance.stop(process_manager)

        %State{state | process_managers: Map.delete(process_managers, process_uuid)}
    end
  end

  defp remove_process_manager(process_managers, pid) do
    Enum.reduce(process_managers, process_managers, fn
      {process_uuid, process_manager_pid}, acc when process_manager_pid == pid ->
        Map.delete(acc, process_uuid)

      _, acc ->
        acc
    end)
  end

  defp do_ack_event(event, %State{} = state) do
    %State{
      consistency: consistency,
      process_manager_name: name,
      subscription: subscription
    } = state

    :ok = EventStore.ack_event(subscription, event)
    :ok = Subscriptions.ack_event(name, consistency, event)
  end

  # Delegate event to process instance who will ack event processing on success
  defp delegate_event(process_instance, %RecordedEvent{} = event, %State{} = state) do
    %State{pending_acks: pending_acks} = state
    %RecordedEvent{event_number: event_number} = event

    :ok = ProcessManagerInstance.process_event(process_instance, event, self())

    %State{
      state
      | pending_acks:
          Map.update(pending_acks, event_number, [process_instance], fn pending ->
            [process_instance | pending]
          end)
    }
  end

  defp describe(%State{process_manager_module: process_manager_module}),
    do: inspect(process_manager_module)
end
