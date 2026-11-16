defmodule ServidorInventario do
  @moduledoc """
  GenServer que administra el inventario compartido de recursos.

  ¿Cómo evita inconsistencias?
  Un GenServer atiende los mensajes de su buzón UNO A LA VEZ. Cuando dos usuarios
  piden el mismo recurso al mismo tiempo, sus solicitudes quedan en fila y cada
  handle_call valida la cantidad y descuenta en el mismo paso. Cuando llega la segunda
  solicitud, la primera ya fue descontada, por lo que la segunda ve el inventario real.
  Nunca se consulta el inventario por fuera para modificarlo después.

  Estado: %{recursos: [lista de recursos], movimientos: [historial]}
  """
  use GenServer

  # ---------------------------------------------------------------
  # API pública (la usan la interfaz, Necesidades y los procesos de usuarios)
  # ---------------------------------------------------------------

  def start_link(_opciones \\ []) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  def registrar_recurso(datos, usuario), do: GenServer.call(__MODULE__, {:registrar, datos, usuario})
  def listar_recursos, do: GenServer.call(__MODULE__, :listar)
  def buscar_recurso(codigo), do: GenServer.call(__MODULE__, {:buscar, codigo})
  def disponibilidad(categoria, zona), do: GenServer.call(__MODULE__, {:disponibilidad, categoria, zona})
  def registrar_entrada(codigo, cantidad, usuario), do: GenServer.call(__MODULE__, {:entrada, codigo, cantidad, usuario})
  def registrar_salida(codigo, cantidad, usuario), do: GenServer.call(__MODULE__, {:salida, codigo, cantidad, usuario})

  # Asigna una cantidad de un recurso (código o categoría) a una necesidad.
  def asignar(referencia, cantidad, id_necesidad, usuario) do
    GenServer.call(__MODULE__, {:asignar, referencia, cantidad, id_necesidad, usuario})
  end

  def transferir(codigo, origen, destino, cantidad, zona_destino, usuario) do
    GenServer.call(__MODULE__, {:transferir, codigo, origen, destino, cantidad, zona_destino, usuario})
  end

  def movimientos(codigo \\ ""), do: GenServer.call(__MODULE__, {:movimientos, codigo})

  # ---------------------------------------------------------------
  # Callbacks del GenServer
  # ---------------------------------------------------------------

  # Al iniciar (o reiniciar por el supervisor) se recupera el inventario desde los archivos.
  @impl true
  def init(:ok) do
    estado = %{recursos: Persistencia.cargar_recursos(), movimientos: Persistencia.cargar_movimientos()}
    {:ok, estado}
  end

  @impl true
  def handle_call({:registrar, datos, usuario}, _de, estado) do
    case Recursos.registrar_recurso(estado.recursos, datos) do
      {:ok, recursos, recurso} ->
        mov = Recursos.crear_movimiento(:entrada, recurso.codigo, recurso.cantidad, "registro inicial", usuario)
        {:reply, {:ok, recurso}, guardar(estado, recursos, mov)}

      error ->
        {:reply, error, estado}
    end
  end

  def handle_call(:listar, _de, estado), do: {:reply, estado.recursos, estado}

  def handle_call({:buscar, codigo}, _de, estado) do
    {:reply, Recursos.buscar_recurso(estado.recursos, codigo), estado}
  end

  def handle_call({:disponibilidad, categoria, zona}, _de, estado) do
    {:reply, Recursos.disponibilidad(estado.recursos, categoria, zona), estado}
  end

  def handle_call({:entrada, codigo, cantidad, usuario}, _de, estado) do
    case Recursos.registrar_entrada(estado.recursos, codigo, cantidad) do
      {:ok, recursos, recurso} ->
        mov = Recursos.crear_movimiento(:entrada, codigo, cantidad, "entrada de inventario", usuario)
        {:reply, {:ok, recurso}, guardar(estado, recursos, mov)}

      error ->
        {:reply, error, estado}
    end
  end

  def handle_call({:salida, codigo, cantidad, usuario}, _de, estado) do
    case Recursos.registrar_salida(estado.recursos, codigo, cantidad) do
      {:ok, recursos, recurso} ->
        mov = Recursos.crear_movimiento(:salida, codigo, cantidad, "salida de inventario", usuario)
        {:reply, {:ok, recurso}, guardar(estado, recursos, mov)}

      error ->
        {:reply, error, estado}
    end
  end

  # Sección crítica: validar + descontar ocurre dentro del mismo handle_call.
  def handle_call({:asignar, referencia, cantidad_recibida, id_necesidad, usuario}, _de, estado) do
    # Se trabaja siempre con la cantidad ya convertida a número (puede llegar como texto).
    resultado =
      case Utilidades.a_cantidad_positiva(cantidad_recibida) do
        {:ok, cantidad} -> {cantidad, Recursos.asignar(estado.recursos, referencia, cantidad)}
        error -> {0, error}
      end

    case resultado do
      {cantidad, {:ok, recursos, recurso}} ->
        mov = Recursos.crear_movimiento(:asignacion, recurso.codigo, cantidad, "asignado a " <> id_necesidad, usuario)
        respuesta = %{recurso: recurso.codigo, cantidad: cantidad, restante: recurso.cantidad, necesidad: id_necesidad}
        {:reply, {:ok, respuesta}, guardar(estado, recursos, mov)}

      {_cantidad, error} ->
        {:reply, error, estado}
    end
  end

  def handle_call({:transferir, codigo, origen, destino, cantidad, zona_destino, usuario}, _de, estado) do
    case Recursos.transferir(estado.recursos, codigo, origen, destino, cantidad, zona_destino) do
      {:ok, recursos, codigo_destino} ->
        salida = Recursos.crear_movimiento(:transferencia_salida, codigo, cantidad, "hacia " <> destino, usuario)
        entrada = Recursos.crear_movimiento(:transferencia_entrada, codigo_destino, cantidad, "desde " <> origen, usuario)
        nuevo_estado = estado |> guardar(recursos, salida) |> guardar(recursos, entrada)
        {:reply, {:ok, codigo_destino}, nuevo_estado}

      error ->
        {:reply, error, estado}
    end
  end

  def handle_call({:movimientos, codigo}, _de, estado) do
    {:reply, Recursos.movimientos_de(estado.movimientos, codigo), estado}
  end

  # Actualiza el estado, agrega el movimiento al historial y guarda en los archivos.
  defp guardar(estado, recursos, movimiento) do
    movimientos = estado.movimientos ++ [movimiento]
    Persistencia.guardar_recursos(recursos)
    Persistencia.guardar_movimientos(movimientos)
    %{estado | recursos: recursos, movimientos: movimientos}
  end
end
