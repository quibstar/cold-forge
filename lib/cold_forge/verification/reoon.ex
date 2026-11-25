defmodule ColdForge.Verification.Reoon do
  @moduledoc """
  Reoon Email Verifier's API: one address at a time for the contact finder, and
  bulk tasks for checking a whole list.

  Always power mode. Quick mode only looks at the domain, and every address
  that has bounced on us sat on a domain that accepts mail: it was the mailbox
  that didn't exist, which only power mode asks the mail server about.

  The key comes from `REOON_API_KEY` and is sent as a query parameter, as
  Reoon requires; it is never logged or put into an error.
  """

  @base "https://emailverifier.reoon.com/api/v1"

  # Power mode can take a minute on a slow mail server.
  @verify_timeout 90_000

  def configured?, do: match?({:ok, _}, api_key())

  @doc """
  Checks one address. `{:ok, %{status: "invalid", score: 3}}`, or an error that
  callers treat as "not checked" rather than as a verdict.
  """
  @spec verify(String.t()) ::
          {:ok, %{status: String.t(), score: integer() | nil}} | {:error, term()}
  def verify(email) when is_binary(email) do
    with {:ok, key} <- api_key(),
         {:ok, %{status: 200, body: %{"status" => status} = body}} when is_binary(status) <-
           get("/verify", [email: email, key: key, mode: "power"], @verify_timeout) do
      {:ok, %{status: status, score: body["overall_score"]}}
    else
      other -> error(other)
    end
  end

  @doc "Starts a bulk task. Reoon takes up to 50,000 addresses in one."
  @spec create_bulk([String.t()], String.t()) :: {:ok, String.t()} | {:error, term()}
  def create_bulk(emails, name) when is_list(emails) do
    with {:ok, key} <- api_key(),
         {:ok, %{status: status, body: %{"status" => "success", "task_id" => task_id}}}
         when status in [200, 201] <-
           request(:post, "/create-bulk-verification-task/",
             json: %{name: String.slice(name, 0, 25), emails: emails, key: key}
           ) do
      {:ok, to_string(task_id)}
    else
      other -> error(other)
    end
  end

  @doc """
  A bulk task's progress, or its results once it's done: `{:running, percent}`,
  or `{:done, %{"a@b.com" => "invalid", ...}}`.
  """
  @spec bulk_result(String.t()) ::
          {:ok, {:running, number()} | {:done, %{String.t() => String.t()}}} | {:error, term()}
  def bulk_result(task_id) do
    with {:ok, key} <- api_key(),
         {:ok, %{status: 200, body: %{"status" => task_status} = body}} <-
           get("/get-result-bulk-verification-task/", [key: key, task_id: task_id], 30_000) do
      case task_status do
        s when s in ["waiting", "running"] -> {:ok, {:running, body["progress_percentage"] || 0}}
        "completed" -> {:ok, {:done, results(body["results"])}}
        "error" -> {:error, {:reoon, body["reason"]}}
        other -> {:error, {:task, other}}
      end
    else
      other -> error(other)
    end
  end

  @doc "Instant and daily credits left."
  def balance do
    with {:ok, key} <- api_key(),
         {:ok, %{status: 200, body: %{"status" => "success"} = body}} <-
           get("/check-account-balance/", [key: key], 15_000) do
      {:ok,
       %{
         instant: body["remaining_instant_credits"],
         daily: body["remaining_daily_credits"],
         api_status: body["api_status"]
       }}
    else
      other -> error(other)
    end
  end

  # The docs show results keyed by address; their prose says a list. Take both.
  defp results(map) when is_map(map) do
    Map.new(map, fn {email, row} -> {String.downcase(email), row_status(row)} end)
  end

  defp results(list) when is_list(list) do
    Map.new(list, fn row -> {String.downcase(to_string(row["email"])), row_status(row)} end)
  end

  defp results(_), do: %{}

  defp row_status(%{"status" => status}) when is_binary(status), do: status
  defp row_status(_), do: "unknown"

  defp get(path, params, timeout),
    do: request(:get, path, params: params, receive_timeout: timeout)

  defp request(method, path, opts) do
    [method: method, url: @base <> path, retry: false, receive_timeout: 30_000]
    |> Keyword.merge(opts)
    |> Keyword.merge(Application.get_env(:cold_forge, :reoon_req_options, []))
    |> Req.request()
  end

  # Error bodies are `{"status": "error", "reason": ...}`; keep the reason only,
  # never the request, which carries the key.
  defp error({:error, :no_api_key}), do: {:error, :no_api_key}

  defp error({:ok, %{status: status, body: %{"reason" => reason}}}),
    do: {:error, {:http, status, reason}}

  defp error({:ok, %{status: status}}), do: {:error, {:http, status}}
  defp error({:error, %{reason: reason}}), do: {:error, {:transport, reason}}
  defp error({:error, reason}), do: {:error, reason}

  defp api_key do
    case Application.get_env(:cold_forge, :reoon_api_key) do
      key when is_binary(key) and key != "" -> {:ok, key}
      _ -> {:error, :no_api_key}
    end
  end
end
