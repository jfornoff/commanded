defmodule Commanded.ExampleDomain.BankRouter do
  @moduledoc false
  use Commanded.Commands.Router

  alias Commanded.ExampleDomain.{
    BankAccount,
    DepositMoneyHandler,
    MoneyTransfer,
    OpenAccountHandler,
    TransferMoneyHandler,
    WithdrawMoneyHandler
  }

  alias BankAccount.Commands.{
    DepositMoney,
    OpenAccount,
    WithdrawMoney
  }

  alias MoneyTransfer.Commands.TransferMoney
  alias Commanded.Helpers.CommandAuditMiddleware

  middleware(CommandAuditMiddleware)

  identify(BankAccount, by: :account_number)
  identify(MoneyTransfer, by: :transfer_uuid)

  dispatch(OpenAccount, to: OpenAccountHandler, aggregate: BankAccount)
  dispatch(DepositMoney, to: DepositMoneyHandler, aggregate: BankAccount)
  dispatch(WithdrawMoney, to: WithdrawMoneyHandler, aggregate: BankAccount)

  dispatch(TransferMoney, to: TransferMoneyHandler, aggregate: MoneyTransfer)
end
