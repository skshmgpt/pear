defmodule Pear do
  def new(name, port, peers) do
    :persistent_term.put(:self_name, name)
    IO.puts("port : #{port}")
    Pear.Router.start()
    start(port)
    connect_all(peers)
    Pear.CLI.loop()
  end

  def start(port) do
    {:ok, ls} = Pear.Listener.listen(port)
    spawn(fn -> Pear.Listener.accept(ls) end)
  end

  def connect(node_ip, node_port, name) do
    IO.puts("connecting to #{name}, #{node_ip}, #{node_port}")

    {:ok, sock} =
      :gen_tcp.connect(String.to_charlist(node_ip), node_port, [:binary, active: false])

    send(:router, {:add, name, sock})
    spawn(fn -> Pear.Reader.loop(sock, name) end)
  end

  def connect_all(peers) do
    Enum.each(peers, fn {name, ip, port} ->
      IO.puts("connecting to #{name}, #{ip}, #{port}")
      connect(ip, port, name)
    end)
  end
end

defmodule Pear.Listener do
  def listen(port) do
    :gen_tcp.listen(port, [
      :binary,
      active: false,
      reuseaddr: true
    ])
  end

  def accept(ls) do
    {:ok, socket} = :gen_tcp.accept(ls)
    name = "peer_#{:rand.uniform(1000)}"
    spawn(fn -> Pear.Reader.loop(socket, name) end)
    send(:router, {:add, name, socket})
    accept(ls)
  end
end

defmodule Pear.Reader do
  def loop(socket, name) do
    case :gen_tcp.recv(socket, 0) do
      {:ok, data} ->
        data |> Utils.deserialize() |> handle_message(name)
        loop(socket, name)

      {:error, :closed} ->
        IO.puts("#{name} [disconnected]")
        send(:router, {:remove, name})
    end
  end

  def handle_message(%{type: :broadcast, from: from, body: body}, _received_from) do
    IO.puts("[#{from}] #{body}")
  end

  def handle_message(%{type: :direct, from: from, body: body}, _received_from) do
    IO.puts("[#{from} -> you] #{body}")
  end

  def handle_message(
        %{type: :forward, to: to, from: from, body: body, visited: visited},
        received_from
      ) do
    self_name = :persistent_term.get(:self_name)

    cond do
      to == self_name ->
        hops = visited |> Enum.reverse() |> Enum.join(" → ")
        IO.puts("[#{from}] #{body} (via #{hops})")

      true ->
        send(
          :router,
          {:forward, %{type: :forward, to: to, from: from, body: body, visited: visited},
           received_from}
        )
    end
  end
end

defmodule Pear.CLI do
  def loop do
    case IO.gets("> ") do
      :eof ->
        IO.puts("EOF")

      input ->
        input |> String.trim() |> handle_input()
        loop()
    end
  end

  @doc """
  parses peer name from the input string
  if present

  """
  def handle_input("@" <> rest) do
    # rest is the peer name + space + msg in this case
    # separates name and msg on the first space
    [name | msg_parts] = String.split(rest, " ", parts: 2)
    msg = List.first(msg_parts, "")
    send(:router, {:send_to, name, msg})
  end

  def handle_input(msg) do
    send(:router, {:broadcast, msg})
  end
end

defmodule Pear.Router do
  def start do
    pid = spawn(fn -> loop(%{}) end)
    Process.register(pid, :router)
    pid
  end

  def loop(peers) do
    receive do
      {:add, name, socket} ->
        loop(Map.put(peers, name, socket))

      {:broadcast, msg} ->
        payload =
          Utils.serialize(%{type: :broadcast, from: :persistent_term.get(:self_name), body: msg})

        Enum.each(peers, fn {_name, socket} -> :gen_tcp.send(socket, payload) end)
        loop(peers)

      {:remove, name} ->
        loop(Map.delete(peers, name))

      {:send_to, name, msg} ->
        case Map.get(peers, name) do
          nil ->
            forward_payload = %{
              type: :forward,
              from: :persistent_term.get(:self_name),
              to: name,
              body: msg,
              visited: [:persistent_term.get(:self_name)]
            }

            Enum.each(peers, fn {_name, socket} ->
              :gen_tcp.send(socket, :erlang.term_to_binary(forward_payload))
            end)

          socket ->
            payload =
              Utils.serialize(%{type: :direct, from: :persistent_term.get(:self_name), body: msg})

            :gen_tcp.send(socket, payload)
        end

        loop(peers)

      {:forward, msg, received_from} ->
        # called from reader, with the deserialized msg
        self_name = :persistent_term.get(:self_name)

        case Map.get(peers, msg.to) do
          nil ->
            # not a direct peer, flood each peer
            Enum.each(peers, fn {name, socket} ->
              if name == received_from or name in msg.visited do
                # this does nothing (intended)
                :drop
              else
                :gen_tcp.send(
                  socket,
                  Utils.serialize(%{msg | visited: [self_name | msg.visited]})
                )
              end
            end)

          socket ->
            # direct peer
            :gen_tcp.send(socket, Utils.serialize(msg))
        end

        loop(peers)
    end
  end
end

defmodule Utils do
  def serialize(msg) do
    :erlang.term_to_binary(msg)
  end

  def deserialize(msg) do
    :erlang.binary_to_term(msg)
  end
end
