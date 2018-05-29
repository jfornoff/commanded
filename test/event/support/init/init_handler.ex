defmodule Commanded.Event.InitHandler do
  use Commanded.Event.Handler, name: __MODULE__

  def init do
    send(reply_to(), {:init, self()})

    :ok
  end

  defp reply_to do
    Agent.get({:global, __MODULE__}, fn reply_to -> reply_to end)
  end
end
