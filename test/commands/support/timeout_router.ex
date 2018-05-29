defmodule Commanded.Commands.TimeoutRouter do
  @moduledoc false
  use Commanded.Commands.Router

  alias Commanded.Commands.{TimeoutAggregateRoot, TimeoutCommandHandler, TimeoutCommand}

  dispatch(
    TimeoutCommand,
    to: TimeoutCommandHandler,
    aggregate: TimeoutAggregateRoot,
    identity: :aggregate_uuid,
    timeout: 1_000
  )
end
