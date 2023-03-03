defmodule Photon.HTTP.Response do
    def parse({error, r}) do
        {error, r}
    end

    def parse(r) do
        cond do
            !r[:step] ->
                parse(read_response_code(r))
            r.step == :headers ->
                parse(Photon.HTTP.Headers.parse(r))
            r.step == :body and r.headers["connection"] == "upgrade" -> Map.merge(r, %{step: :next})
            r.step == :body -> r
        end
    end

    def read_response_code(r) do
        case :binary.split(r.buf, "\r\n") do
            [response, buf] ->
                [_http11,rest] = :binary.split(response, " ")
                [status_code,status_text] = :binary.split(rest, " ")
                Map.merge(r, %{status_code: :erlang.binary_to_integer(status_code), status_text: status_text, buf: buf, step: :headers})
            _ -> {:partial, r}
        end
    end

    def build_status_text(status_code, status_text \\ nil) do
        cond do
            status_text -> status_text
            status_code == 200 -> "OK"
            status_code == 302 -> "Found"
            status_code == 404 -> "Not Found"
            true -> "OK"
        end
    end

    def build(response) do
        headers = Photon.HTTP.Headers.build(response[:headers]||%{})
        status_text = build_status_text(response.status_code, response[:status_text])
        "HTTP/1.1 #{response.status_code} #{status_text}\r\n#{headers}\r\n\r\n#{response[:body]}"
    end

    def build_cors(request, status_code\\ 200, extra_headers \\ %{}, body \\ "") do
        headers = %{}
        |> Photon.HTTP.Headers.add_cors()
        |> Photon.HTTP.Headers.add_date()
        |> Photon.HTTP.Headers.add_connection(request)

        {headers, body} = cond do
            is_map(body) or is_list(body) -> 
                {Map.put(headers, "Content-Type", "application/json; charset=utf-8"), JSX.encode!(body)}
            true -> {headers, body}
        end
        headers = if !!extra_headers["Content-Length"] or !!extra_headers["content-length"] do headers else
            Map.put(headers, "Content-Length", "#{byte_size(body)}")
        end
        extra_headers = Enum.into(extra_headers, %{}, fn{k,v}-> {"#{k}",v} end)
        headers = Map.merge(headers, extra_headers)

        build(%{status_code: status_code, headers: headers, body: body})
    end

    def build_cached(state, map) do
        headers = %{
            "Content-Type"=> "text/html; charset=utf-8"
        }
        |> Photon.HTTP.Headers.add_date()
        |> Photon.HTTP.Headers.add_connection(state.request)

        h = state.request.headers
        can_gzip = Photon.HTTP.Headers.can_accept_gzip(h)
        cond do
            can_gzip and Photon.HTTP.Headers.is_cached(h, map.crc32_gzipped) ->
                headers = Map.merge(headers, %{"Etag"=> map.crc32_gzipped})
                |> Photon.HTTP.Headers.add_content_length("")
                reply = build(%{status_code: 304, headers: headers})
                :ok = :gen_tcp.send(state.socket, reply)
                state
            can_gzip ->
                headers = Map.merge(headers, %{"Content-Encoding"=> "gzip", "Etag"=> map.crc32_gzipped})
                |> Photon.HTTP.Headers.add_content_length(map.gzipped)
                reply = build(
                    %{status_code: 200, headers: headers, body: map.gzipped})
                :ok = :gen_tcp.send(state.socket, reply)
                state

            !can_gzip and Photon.HTTP.Headers.is_cached(h, map.crc32_bin) ->
                headers = Map.merge(headers, %{"Etag"=> map.crc32_bin})
                |> Photon.HTTP.Headers.add_content_length("")
                reply = build(%{status_code: 304, headers: headers})
                :ok = :gen_tcp.send(state.socket, reply)
                state
            !can_gzip ->
                headers = Map.merge(headers, %{"Etag"=> map.crc32_bin})
                |> Photon.HTTP.Headers.add_content_length(map.bin)
                reply = build(
                    %{status_code: 200, headers: headers, body: map.bin})
                :ok = :gen_tcp.send(state.socket, reply)
                state
        end
    end
end
