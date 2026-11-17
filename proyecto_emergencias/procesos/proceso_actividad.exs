defmodule ProcesoActividad do
  @moduledoc """
  Proceso independiente (creado con spawn_link, sin GenServer) que registra la
  actividad de los usuarios en datos/actividad.txt.

  - Los demás procesos le envían mensajes con send/2 y siguen trabajando sin esperar.
  - El proceso los atiende con receive en un ciclo recursivo (ciclo/0 se llama a sí mismo).
  - También está bajo el SupervisorEmergencia: si muere, el supervisor lo vuelve a crear.
  """

  @nombre :proceso_actividad

  # Especificación para que el Supervisor sepa cómo iniciarlo.
  def child_spec(_argumento) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, []}}
  end

  # spawn_link enlaza el proceso con quien lo crea (el supervisor).
  def start_link do
    pid = spawn_link(fn -> ciclo() end)
    Process.register(pid, @nombre)
    {:ok, pid}
  end

  # Envía la actividad de forma asíncrona (no espera respuesta).
  def registrar(usuario, accion) do
    case Process.whereis(@nombre) do
      nil -> {:error, :proceso_no_disponible}
      pid ->
        send(pid, {:registrar, usuario, accion})
        :ok
    end
  end

  # Pide la bitácora completa y espera la respuesta.
  def consultar do
    case Process.whereis(@nombre) do
      nil ->
        []

      pid ->
        referencia = make_ref()
        send(pid, {:consultar, self(), referencia})

        receive do
          {:actividad, ^referencia, registros} -> registros
        after
          3000 -> []
        end
    end
  end

  # Ciclo recursivo del proceso: espera un mensaje, lo atiende y vuelve a esperar.
  defp ciclo do
    receive do
      {:registrar, usuario, accion} ->
        Persistencia.registrar_actividad(usuario, accion)
        ciclo()

      {:consultar, quien, referencia} ->
        send(quien, {:actividad, referencia, Persistencia.cargar_actividad()})
        ciclo()

      _otro ->
        ciclo()
    end
  end
end
