defmodule Photon.HTTP do
    def read_body_all(state) do
        r = state.request
        #TODO: add support for chunk-encoding and other fun stuff
        cl = Map.fetch!(r.headers, "content-length")
        |> :erlang.binary_to_integer()
        to_recv = cl - byte_size(r.buf)
        if to_recv > 0 do
            {:ok, bin} = :gen_tcp.recv(state.socket, to_recv)
            state = put_in(state, [:request, :buf], "")
            {state, r.buf<>bin}
        else
            <<bin::binary-size(cl), buf::binary>> = r.buf
            state = put_in(state, [:request, :buf], buf)
            {state, bin}
        end
    end

    def read_body_all_json(state, json_args \\ [{:labels, :attempt_atom}]) do
        {state, bin} = read_body_all(state)
        json = JSX.decode!(bin, json_args)
        {state, json}
    end

    def download_chunks(state, f) do
        r = state.request
        #TODO: support chunked
        cl = Map.fetch!(r.headers, "content-length") |> :erlang.binary_to_integer()
        to_recv = cl - byte_size(r.buf)
        if to_recv > 0 do
            :file.write(f, r.buf)
            download_chunks_1(state, f, to_recv)
        else
            <<bin::binary-size(cl), buf::binary>> = r.buf
            :file.write(f, bin)
            put_in(state, [:request, :buf], buf)
        end
    end

    def download_chunks_1(state, f, to_recv) do
        #TODO: autoscale bigger buffer for faster inet
        chunk = min(to_recv, 8_388_608)
        {:ok, bin} = :gen_tcp.recv(state.socket, chunk, 120_000)
        recv_size = byte_size(bin)
        left = to_recv - recv_size
        if left > 0 do
            :file.write(f, bin)
            download_chunks_1(state, f, left)
        else
            <<payload::binary-size(to_recv), buf::binary>> = bin
            :file.write(f, payload)
            put_in(state, [:request, :buf], buf)
        end
    end

    def read_body_to_file(state, path) do
        File.mkdir_p!(Path.dirname(path))
        {:ok, f} = :file.open(path, [:raw, :write])
        state = download_chunks(state, f)
        :file.close(f)
        state
    end

    def parse_query(query, to_atom \\ true) do
        String.split(query, "&")
        |> Enum.into(%{}, fn(line)->
            [k,v] = :binary.split(line, "=")
            k = if !to_atom do k else
                try do
                    String.to_existing_atom(k)
                catch _,_ -> k end
            end
            {k,v}
        end)
    end

    def merge_query_body(state, query) do
        if state.request.method in ["PUT", "POST", "PATCH"] do
            {state, json} = read_body_all_json(state)
            {state, Map.merge(query||%{}, json)}
        else {state, query} end
    end

    def sanitize_path(path) do
        dir = :filename.dirname(path)
        |> :re.replace("[^0-9A-Za-z\\-\\_\\/]", "", [:global, {:return, :binary}])
        filename = :filename.basename(path)
        |> :re.replace("[^0-9A-Za-z\\-\\_\\.]", "", [:global, {:return, :binary}])
        
        sanitize_path_1("#{dir}/#{filename}")
    end

    defp sanitize_path_1(path) do
        path = :binary.replace(path,"//","/")
        case :binary.match(path,"//") do
            :nomatch ->
                case path do
                    <<"/", path::binary>> -> path
                    _ -> path
                end
            _ -> sanitize_path_1(path)
        end
    end
end
