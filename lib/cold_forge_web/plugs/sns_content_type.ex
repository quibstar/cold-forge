defmodule ColdForgeWeb.Plugs.SNSContentType do
  @moduledoc """
  Makes SNS's JSON parseable.

  Amazon SNS POSTs JSON but labels it `text/plain; charset=UTF-8`. Plug's JSON
  parser goes by content type, so the body is never decoded: the controller
  receives no fields at all, decides it has nothing to act on, and answers 200.
  Every bounce and every reply is silently dropped, and the endpoint looks
  perfectly healthy while doing it — a fast 200 and no log line.

  The `x-amz-sns-message-type` header is the tell. It is present on every SNS
  delivery and on nothing else, so it is what this keys on rather than the path,
  and the rewrite happens only for requests that really are SNS.
  """
  @behaviour Plug

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    case Plug.Conn.get_req_header(conn, "x-amz-sns-message-type") do
      [_ | _] ->
        headers =
          List.keystore(conn.req_headers, "content-type", 0, {"content-type", "application/json"})

        %{conn | req_headers: headers}

      [] ->
        conn
    end
  end
end
