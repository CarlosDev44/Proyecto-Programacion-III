defmodule ServidorAlbergues do
  @moduledoc """
  GenServer que administra la ocupación de los albergues.

  Igual que el inventario: cada ingreso se valida y se registra dentro del mismo
  handle_call. Si llegan muchos ingresos simultáneos al último cupo, solo el primero
  que el GenServer procese obtiene el cupo; los demás reciben {:error, :capacidad_superada}.

  Estado: lista de albergues.
  """
  use GenServer

  # ---------------------------------------------------------------
  # API pública
  # ---------------------------------------------------------------

  def start_link(_opciones \\ []) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  def registrar_albergue(datos), do: GenServer.call(__MODULE__, {:registrar, datos})
  def listar_albergues, do: GenServer.call(__MODULE__, :listar)
  def consultar(codigo), do: GenServer.call(__MODULE__, {:consultar, codigo})
  def registrar_ingreso(codigo, documento), do: GenServer.call(__MODULE__, {:ingreso, codigo, documento})
  def registrar_salida(codigo, documento), do: GenServer.call(__MODULE__, {:salida, codigo, documento})
  def reporte_ocupacion, do: GenServer.call(__MODULE__, :reporte)

  # ---------------------------------------------------------------
  # Callbacks
  # ---------------------------------------------------------------

  @impl true
  def init(:ok), do: {:ok, Persistencia.cargar_albergues()}

  @impl true
  def handle_call({:registrar, datos}, _de, albergues) do
    responder_y_guardar(Albergues.registrar_albergue(albergues, datos), albergues)
  end

  def handle_call(:listar, _de, albergues), do: {:reply, albergues, albergues}

  def handle_call({:consultar, codigo}, _de, albergues) do
    {:reply, Albergues.buscar(albergues, codigo), albergues}
  end

  # Sección crítica: se verifica la capacidad y se suma la ocupación en el mismo paso.
  def handle_call({:ingreso, codigo, documento}, _de, albergues) do
    responder_y_guardar(Albergues.registrar_ingreso(albergues, codigo, documento), albergues)
  end

  def handle_call({:salida, codigo, documento}, _de, albergues) do
    responder_y_guardar(Albergues.registrar_salida(albergues, codigo, documento), albergues)
  end

  def handle_call(:reporte, _de, albergues) do
    {:reply, Albergues.reporte_ocupacion(albergues), albergues}
  end

  # Si la operación fue exitosa se guarda en el archivo y se actualiza el estado.
  defp responder_y_guardar({:ok, nuevos, albergue}, _albergues) do
    Persistencia.guardar_albergues(nuevos)
    {:reply, {:ok, albergue}, nuevos}
  end

  defp responder_y_guardar(error, albergues), do: {:reply, error, albergues}
end
