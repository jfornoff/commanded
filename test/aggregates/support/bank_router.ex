defmodule Commanded.Aggregates.BankRouter do
  @moduledoc false
  use Commanded.Commands.Router

  alias Commanded.Aggregates.BankAccountLifespan

  alias Commanded.ExampleDomain.{
    BankAccount,
    OpenAccountHandler,
    DepositMoneyHandler,
    WithdrawMoneyHandler
  }

  alias BankAccount.Commands.{
    CloseAccount,
    DepositMoney,
    OpenAccount,
    WithdrawMoney
  }

  dispatch(
    OpenAccount,
    to: OpenAccountHandler,
    aggregate: BankAccount,
    lifespan: BankAccountLifespan,
    identity: :account_number
  )

  dispatch(
    DepositMoney,
    to: DepositMoneyHandler,
    aggregate: BankAccount,
    lifespan: BankAccountLifespan,
    identity: :account_number
  )

  dispatch(
    WithdrawMoney,
    to: WithdrawMoneyHandler,
    aggregate: BankAccount,
    identity: :account_number
  )

  dispatch(
    CloseAccount,
    to: OpenAccountHandler,
    aggregate: BankAccount,
    lifespan: BankAccountLifespan,
    identity: :account_number
  )
end
