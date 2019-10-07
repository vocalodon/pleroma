defmodule Pleroma.Application do
  use Application

  # See http://elixir-lang.org/docs/stable/elixir/Application.html
  # for more information on OTP Applications
  def start(_type, _args) do
    import Supervisor.Spec
    import Cachex.Spec

    # Define workers and child supervisors to be supervised
    children =
      [
        # Start the Ecto repository
        supervisor(Pleroma.Repo, []),
        # Start the endpoint when the application starts
        supervisor(Pleroma.Web.Endpoint, []),
        # Start your own worker by calling: Pleroma.Worker.start_link(arg1, arg2, arg3)
        # worker(Pleroma.Worker, [arg1, arg2, arg3]),
        worker(Cachex, [
          :user_cache,
          [
            default_ttl: 25000,
            ttl_interval: 1000,
            limit: 2500
          ]
        ]),
        worker(
          Cachex,
          [
            :idempotency_cache,
            [
              expiration:
                expiration(
                  default: :timer.seconds(6 * 60 * 60),
                  interval: :timer.seconds(60)
                ),
              limit: 2500
            ]
          ],
          id: :cachex_idem
        ),
        worker(Pleroma.Web.Federator, []),
        worker(Pleroma.Gopher.Server, []),
        worker(Pleroma.Stats, [])
      ] ++
        if Mix.env() == :test,
          do: [],
          else:
            [worker(Pleroma.Web.Streamer, [])] ++
              if(
                !chat_enabled(),
                do: [],
                else: [worker(Pleroma.Web.ChatChannel.ChatChannelState, [])]
              )

    # See http://elixir-lang.org/docs/stable/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Pleroma.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp chat_enabled do
    Application.get_env(:pleroma, :chat, []) |> Keyword.get(:enabled)
  end
end
