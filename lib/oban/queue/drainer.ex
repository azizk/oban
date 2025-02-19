defmodule Oban.Queue.Drainer do
  @moduledoc false

  import Ecto.Query, only: [where: 3]

  alias Oban.{Config, Job, Repo}
  alias Oban.Queue.{BasicEngine, Executor}

  @infinite 100_000_000

  def drain(%Config{} = conf, [_ | _] = opts) do
    conf = %{conf | engine: BasicEngine}

    args =
      opts
      |> Map.new()
      |> Map.put_new(:with_limit, @infinite)
      |> Map.put_new(:with_recursion, false)
      |> Map.put_new(:with_safety, true)
      |> Map.put_new(:with_scheduled, false)
      |> Map.update!(:queue, &to_string/1)

    drain(conf, %{discard: 0, failure: 0, snoozed: 0, success: 0}, args)
  end

  defp stage_scheduled(conf, queue) do
    query =
      Job
      |> where([j], j.state in ["scheduled", "retryable"])
      |> where([j], j.queue == ^queue)

    Repo.update_all(conf, query, set: [state: "available"])
  end

  defp drain(conf, old_acc, %{queue: queue} = args) do
    if args.with_scheduled, do: stage_scheduled(conf, queue)

    new_acc =
      conf
      |> fetch_available(args)
      |> Enum.reduce(old_acc, fn job, acc ->
        result =
          conf
          |> Executor.new(job)
          |> Executor.put(:safe, args.with_safety)
          |> Executor.call()
          |> case do
            :exhausted -> :discard
            value -> value
          end

        Map.update(acc, result, 1, &(&1 + 1))
      end)

    if args.with_recursion and old_acc != new_acc do
      drain(conf, new_acc, args)
    else
      new_acc
    end
  end

  defp fetch_available(conf, %{queue: queue, with_limit: limit}) do
    {:ok, meta} = conf.engine.init(conf, queue: queue, limit: limit)
    {:ok, {_meta, jobs}} = conf.engine.fetch_jobs(conf, meta, %{})

    jobs
  end
end
