defmodule Gitspace.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    if System.get_env("__BURRITO") == "1" do
      args =
        :init.get_plain_arguments()
        |> Enum.map(&List.to_string/1)

      Gitspace.CLI.main(args)
    end

    children = [
      # Starts a worker by calling: Gitspace.Worker.start_link(arg)
      # {Gitspace.Worker, arg}
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Gitspace.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
