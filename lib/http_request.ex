defmodule Photon.HTTP.Request do
    def parse({error, r}) do
        {error, r}
    end

    def parse(r) do
        cond do
            !r[:step] ->
                parse(read_path(r))
            r.step == :headers ->
                parse(Photon.HTTP.Headers.parse(r))
            r.step == :body and r.method in ["HEAD", "OPTIONS", "GET"] -> Map.merge(r, %{step: :next})
            r.step == :body -> r
        end
    end

    def read_path(r) do
        case :binary.split(r.buf, "\r\n") do
            [request, buf] ->
                [method,path,_] = String.split(request, " ")
                {path, query} = case :binary.split(path, "?") do
                    [path] -> {path, nil}
                    [path, query] -> {path, query}
                end
                Map.merge(r, %{method: method, path: path, query: query, buf: buf, step: :headers})
            _ -> {:partial, r}
        end
    end

    def build(request) do
        headers = Photon.HTTP.Headers.build(request[:headers]||%{})
        "#{request.method} #{request.path} HTTP/1.1\r\n#{headers}\r\n\r\n#{request[:body]}"
    end
end
