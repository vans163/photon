defmodule Photon.GenTCPAcceptor do
    def start_link(port, module) when is_atom(module) do
        pid = :erlang.spawn_link(__MODULE__, :init, [port, module])
        {:ok, pid}
    end
    
    def start_link(ip, port, module) when is_atom(module) do
        pid = :erlang.spawn_link(__MODULE__, :init, [ip, port, module])
        {:ok, pid}
    end

    def init(port, module) do
        lsocket = Photon.GenTCP.listen_highthruput(port)
        state = %{ip: {0,0,0,0}, port: port, lsocket: lsocket, module: module}
        accept_loop(state)
    end
    
    def init(ip, port, module) do
        lsocket = Photon.GenTCP.listen_highthruput(port, [{:ifaddr, ip}])
        state = %{ip: ip, port: port, lsocket: lsocket, module: module}
        accept_loop(state)
    end

    def accept_loop(state) do
        {:ok, socket} = :gen_tcp.accept(state.lsocket)
        
        pid = :erlang.spawn(state.module, :init, [%{ip: state.ip, port: state.port, socket: socket}])
        :ok = :gen_tcp.controlling_process(socket, pid)
        send(pid, :socket_ack)

        accept_loop(state)
    end
end