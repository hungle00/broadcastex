defmodule Broadcastex.Auth do
  @doc """
  Tính chữ ký HMAC-SHA256 dạng Hex.
  """
  def hmac_sha256(secret, string_to_sign) do
    :crypto.mac(:hmac, :sha256, secret, string_to_sign)
    |> Base.encode16(case: :lower)
  end

  @doc """
  Xác thực auth token phía client cho Private Channels:
  HMAC_SHA256(secret, "<socket_id>:<channel_name>")
  """
  def verify_channel_auth(auth_header, secret, socket_id, channel) do
    # Header client gửi có dạng: "app_key:expected_signature"
    case String.split(auth_header, ":") do
      [_key, signature] ->
        string_to_sign = "#{socket_id}:#{channel}"
        expected_signature = hmac_sha256(secret, string_to_sign)
        Plug.Crypto.secure_compare(signature, expected_signature)

      _ ->
        false
    end
  end

  @doc """
  Xác thực chữ ký HMAC cho HTTP REST API Trigger.
  """
  def verify_rest_signature(conn, app_secret, body_raw) do
    params = conn.query_params

    with {:ok, _auth_key} <- Map.fetch(params, "auth_key"),
         {:ok, auth_timestamp} <- Map.fetch(params, "auth_timestamp"),
         {:ok, auth_signature} <- Map.fetch(params, "auth_signature"),
         {:ok, body_md5} <- Map.fetch(params, "body_md5"),
         true <- validate_timestamp(auth_timestamp),
         true <- validate_body_md5(body_raw, body_md5) do

      # 1. Bỏ auth_signature ra khỏi query params để sắp xếp lại string_to_sign
      filtered_params = Map.drop(params, ["auth_signature"])

      sorted_query_string =
        filtered_params
        |> Enum.sort_by(fn {k, _v} -> k end)
        |> Enum.map_join("&", fn {k, v} -> "#{k}=#{v}" end)

      # 2. Xây dựng string_to_sign theo chuẩn Pusher Protocol
      string_to_sign = "#{conn.method}\n#{conn.request_path}\n#{sorted_query_string}"

      # 3. So sánh HMAC signature chống timing attack
      expected_signature = hmac_sha256(app_secret, string_to_sign)
      Plug.Crypto.secure_compare(auth_signature, expected_signature)
    else
      _ -> false
    end
  end

  defp validate_timestamp(timestamp_str) do
    case Integer.parse(timestamp_str) do
      {ts, _} ->
        now = DateTime.utc_now() |> DateTime.to_unix()
        abs(now - ts) <= 600 # Cho phép lệch tối đa 10 phút (600s)
      _ -> false
    end
  end

  defp validate_body_md5(body_raw, expected_md5) do
    computed_md5 = :crypto.hash(:md5, body_raw) |> Base.encode16(case: :lower)
    Plug.Crypto.secure_compare(computed_md5, String.downcase(expected_md5))
  end
end
