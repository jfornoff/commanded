defmodule Commanded.ProcessManagers.ExampleProcessManager do
  @moduledoc false
  alias Commanded.ProcessManagers.{ExampleProcessManager, ExampleRouter}
  alias Commanded.ProcessManagers.ExampleAggregate.Commands.Stop
  alias Commanded.ProcessManagers.ExampleAggregate.Events.{Errored, Started, Interested, Stopped}

  use Commanded.ProcessManagers.ProcessManager,
    name: "ExampleProcessManager",
    router: ExampleRouter

  defstruct status: nil,
            items: []

  def interested?(%Started{aggregate_uuid: aggregate_uuid}), do: {:start, aggregate_uuid}
  def interested?(%Interested{aggregate_uuid: aggregate_uuid}), do: {:continue, aggregate_uuid}
  def interested?(%Errored{aggregate_uuid: aggregate_uuid}), do: {:continue, aggregate_uuid}
  def interested?(%Stopped{aggregate_uuid: aggregate_uuid}), do: {:stop, aggregate_uuid}

  def handle(%ExampleProcessManager{}, %Interested{index: 10, aggregate_uuid: aggregate_uuid}) do
    %Stop{aggregate_uuid: aggregate_uuid}
  end

  def handle(%ExampleProcessManager{}, %Errored{}), do: {:error, :failed}

  ## state mutators

  def apply(%ExampleProcessManager{} = process_manager, %Started{}) do
    %ExampleProcessManager{process_manager | status: :started}
  end

  def apply(%ExampleProcessManager{items: items} = process_manager, %Interested{index: index}) do
    %ExampleProcessManager{process_manager | items: items ++ [index]}
  end
end
