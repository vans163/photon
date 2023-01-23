# photon
Extremely Flexible Web(server)library

![image](https://user-images.githubusercontent.com/3028982/171968539-2af1b7f0-fc22-44ae-aace-c8995c76cf5f.png)

## Why?

After using https://github.com/vans163/stargate for years and years, I realize webservers need to be flexible. 
I constantly found myself patching stargate little by little because each project needed a slightly different feature,
like chunk streaming request, then chunk streaming response, then multiplexing different services on the same socket,
then customizing how websocket paths are mapped, then more. Building a monolith type architecture that stargate was and 
constantly piling on features is not the way to go.

## How then?

`photon` ships as a library with the building blocks required to build web services, it will or includes:

 - [x] HTTP Request and Response builder/parser
 - [x] Websockets frame builder/parser with permessage deflate
 - [x] Steppable functions to parse incoming requests
 - [x] Path and other sanitization
 - [x] GZIP, Cors and other helpers
 - [ ] KTLS
 - [ ] io_uring
 - [ ] quic


## What is it not

A webserver. You cannot run it like a monolith genserver. You need to provide the supervision and socket handling yourself.


## Example handler

This is just a random example.

```elixir
# ex.ex

defmodule Ex do
  use Application

  def start(_type, _args) do
    import Supervisor.Spec, warn: false

    supervisor = Supervisor.start_link([
      {DynamicSupervisor, strategy: :one_for_one, name: Ex.Supervisor, max_seconds: 1, max_restarts: 999_999_999_999}
    ], strategy: :one_for_one)


    {:ok, _} = DynamicSupervisor.start_child(Ex.Supervisor, %{
      id: Photon.GenTCPAcceptor, start: {Photon.GenTCPAcceptor, :start_link, [8080, Ex.MultiServer]}
    })

    supervisor
  end
end
```

```elixir
# multiserver.ex

defmodule Ex.MultiServer do
    def init(state) do
        receive do
            :socket_ack -> :ok
        after 3000 -> throw(:no_socket_passed) end

        state = Map.put(state, :request, %{buf: <<>>})
        :ok = :inet.setopts(state.socket, [{:active, :once}])
        loop_http(state)
    end

    def loop_http(state) do
        receive do
            {:tcp, socket, bin} ->
                request = %{state.request | buf: state.request.buf <> bin}
                case Photon.HTTP.Request.parse(request) do
                    {:partial, request} ->
                        state = put_in(state, [:request], request)
                        :inet.setopts(socket, [{:active, :once}])
                        loop_http(state)
                    request ->
                        state = put_in(state, [:request], request)
                        cond do
                            request[:step] in [:next, :body] ->
                                state = handle_http(state)
                                if request.headers["connection"] in ["close", "upgrade"] do
                                    :gen_tcp.shutdown(socket, :write)
                                else
                                    {_, state} = pop_in(state, [:request, :step])
                                    :inet.setopts(socket, [{:active, :once}])
                                    loop_http(state)
                                end

                            true ->
                                :inet.setopts(socket, [{:active, :once}])
                                loop_http(state)
                        end
                end

            {:tcp_closed, socket} -> :closed
            m -> IO.inspect("MultiServer: #{inspect m}")
        end
    end

    def quick_reply(state, reply) do
        :ok = :gen_tcp.send(state.socket, Photon.HTTP.Response.build_cors(state.request, 200, %{}, reply))
        state
    end

    def handle_http_api(state) do
        r = state.request
        query = r.query && Photon.HTTP.parse_query(r.query)
        cond do
            true ->
                quick_reply(state, %{error: :invalid_path})
        end
    end

    def handle_http(state) do
        r = state.request
        
        cond do
            r.method in ["OPTIONS", "HEAD"] ->
                :ok = :gen_tcp.send(state.socket, Photon.HTTP.Response.build_cors(r, 200, %{}, ""))
                state
             
            r.headers["host"] == "api.gpux.ai" ->
                handle_http_api(state)
                
            r.headers["upgrade"] == "websocket" and String.starts_with?(r.path, "/ws/panel") ->
                WS.init(state)

            r.method == "POST" and String.starts_with?(r.path, "/api/job/create2") ->
                {state, json} = Photon.HTTP.read_body_all_json(state)
                :ok = :gen_tcp.send(state.socket, Photon.HTTP.Response.build_cors(state, 200, %{}, json))
                state

            r.method == "GET" ->
                load_dashboard(state)

            true ->
                :ok = :gen_tcp.send(state.socket, Photon.HTTP.Response.build_cors(state, 404, %{}, %{error: :not_found}))
                state
        end
    end
end
```

```elixir
# ws.ex

defmodule WS do
    def init(state) do
        {wsstate, reply} = Photon.WS.handshake(state.request, %{compress: %{}})
        state = Map.merge(state, wsstate)
        :ok = :gen_tcp.send(state.socket, reply)

        :inet.setopts(state.socket, [{:active, :once}])
        loop(state)
    end

    def loop(state) do
        s = state
        cond do
            ts > (s.lrx + 180_000) -> throw %{error: :ws_dead_3min}
            ts > (s.lrx + 60_000) -> :ok = :gen_tcp.send(state.socket, Photon.WS.encode(:ping))
            true -> nil
        end
        receive do
            {:tcp, socket, bin} ->
                state = %{state | buf: state.buf <> bin, lrx: :os.system_time(1000)}
                state = proc(state)
                :inet.setopts(socket, [{:active, :once}])
                loop(state)
            {:tcp_closed, socket} -> :closed
        after 30_000 ->
            loop(state)
        end
    end

    def proc(state) do
        case Photon.WS.decode_one(state) do
            {state, nil} -> state
            {state, %{op: :close}} ->
                :ok = :gen_tcp.send(state.socket, Photon.WS.encode(:close_normal))
                state
            {state, %{op: :pong}} -> state
            {state, %{op: :ping}} ->
                :ok = :gen_tcp.send(state.socket, Photon.WS.encode(:pong))
                state
            {state, %{op: :text, payload: payload}} ->
                state = proc_json(state, JSX.decode!(payload, [{:labels, :attempt_atom}]))
                proc(state)
            {state, frame} ->
                IO.inspect {:ukn_frame, frame}
                proc(state)
        end
    end

    def proc_json(state, json) do
        IO.inspect json
        state
    end
end
```
