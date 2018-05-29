defmodule Commanded.Aggregate.MultiTest do
  use Commanded.StorageCase

  import Commanded.Enumerable

  alias Commanded.EventStore
  alias Commanded.Aggregate.Multi
  alias Commanded.Aggregate.Multi.BankAccount
  alias Commanded.Aggregate.Multi.BankAccount.Commands.{OpenAccount, WithdrawMoney}
  alias Commanded.Aggregate.Multi.BankAccount.Events.{BankAccountOpened, MoneyWithdrawn}

  defmodule MultiBankRouter do
    use Commanded.Commands.Router

    alias Commanded.Aggregate.Multi.BankAccount
    alias Commanded.Aggregate.Multi.BankAccount.Commands.{OpenAccount, WithdrawMoney}

    dispatch([OpenAccount, WithdrawMoney], to: BankAccount, identity: :account_number)
  end

  test "should return `Commanded.Aggregate.Multi` from command" do
    account_number = UUID.uuid4()

    account =
      BankAccount.apply(%BankAccount{}, %BankAccountOpened{
        account_number: account_number,
        balance: 1_000
      })

    assert %Multi{} =
             multi =
             BankAccount.execute(account, %WithdrawMoney{
               account_number: account_number,
               amount: 100
             })

    assert {account, events} = Multi.run(multi)

    assert account == %BankAccount{
             account_number: account_number,
             balance: 900,
             state: :active
           }

    assert events == [
             %MoneyWithdrawn{account_number: account_number, amount: 100, balance: 900}
           ]
  end

  test "should return errors encountered by `Commanded.Aggregate.Multi`" do
    account_number = UUID.uuid4()

    account =
      BankAccount.apply(%BankAccount{}, %BankAccountOpened{
        account_number: account_number,
        balance: 1_000
      })

    assert %Multi{} =
             multi =
             BankAccount.execute(account, %WithdrawMoney{
               account_number: account_number,
               amount: 1_100
             })

    assert {:error, :insufficient_funds_available} = Multi.run(multi)
  end

  test "should execute command using `Commanded.Aggregate.Multi` and return events" do
    account_number = UUID.uuid4()

    assert :ok =
             MultiBankRouter.dispatch(%OpenAccount{
               account_number: account_number,
               initial_balance: 1_000
             })

    assert :ok =
             MultiBankRouter.dispatch(%WithdrawMoney{account_number: account_number, amount: 250})

    recorded_events = EventStore.stream_forward(account_number, 0) |> Enum.to_list()

    assert pluck(recorded_events, :data) == [
             %BankAccountOpened{account_number: account_number, balance: 1_000},
             %MoneyWithdrawn{account_number: account_number, amount: 250, balance: 750}
           ]
  end

  test "should execute command using `Commanded.Aggregate.Multi` and return any error" do
    account_number = UUID.uuid4()

    assert :ok =
             MultiBankRouter.dispatch(%OpenAccount{
               account_number: account_number,
               initial_balance: 1_000
             })

    assert {:error, :insufficient_funds_available} =
             MultiBankRouter.dispatch(%WithdrawMoney{
               account_number: account_number,
               amount: 1_100
             })

    recorded_events = EventStore.stream_forward(account_number, 0) |> Enum.to_list()

    assert pluck(recorded_events, :data) == [
             %BankAccountOpened{account_number: account_number, balance: 1_000}
           ]
  end
end
