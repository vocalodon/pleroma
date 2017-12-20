defmodule Pleroma.Application do
  use Application

  # See http://elixir-lang.org/docs/stable/elixir/Application.html
  # for more information on OTP Applications
  def start(_type, _args) do
    import Supervisor.Spec

    # Define workers and child supervisors to be supervised
    children = [
      # Start the Ecto repository
      supervisor(Pleroma.Repo, []),
      # Start the endpoint when the application starts
      supervisor(Pleroma.Web.Endpoint, []),
      # Start your own worker by calling: Pleroma.Worker.start_link(arg1, arg2, arg3)
      # worker(Pleroma.Worker, [arg1, arg2, arg3]),
      worker(Cachex, [:user_cache, [
                         default_ttl: 25000,
                         ttl_interval: 1000,
                         limit: 2500
                       ]]),
      worker(Pleroma.Web.Federator, []),
      worker(Pleroma.Web.ChatChannel.ChatChannelState, []),
    ]
    ++ if Mix.env == :test, do: [], else: [worker(Pleroma.Web.Streamer, [])]

    # See http://elixir-lang.org/docs/stable/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Pleroma.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
