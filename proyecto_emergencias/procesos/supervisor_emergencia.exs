defmodule SupervisorEmergencia do
  @moduledoc """
  Supervisor principal del sistema. Estrategia :one_for_one:
  si un hijo falla, SOLO ese hijo se reinicia; los demás siguen funcionando.

      SupervisorEmergencia (:one_for_one)
      ├── ProcesoActividad    (proceso con spawn_link + receive)
      ├── ServidorInventario  (GenServer)
      └── ServidorAlbergues   (GenServer)

  Al reiniciarse, los GenServer recuperan su estado desde los archivos de texto.
  """
  use Supervisor

  def start_link(_opciones \\ []) do
    Supervisor.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @impl true
  def init(:ok) do
    hijos = [ProcesoActividad, ServidorInventario, ServidorAlbergues]
    Supervisor.init(hijos, strategy: :one_for_one)
  end

  # Lista los procesos hijos con su PID (para mostrarlo en la interfaz).
  def hijos do
    Enum.map(Supervisor.which_children(__MODULE__), fn {id, pid, _tipo, _modulos} -> {id, pid} end)
  end

  # Simula una falla matando un proceso hijo; el supervisor lo reinicia automáticamente.
  def simular_falla(nombre_registrado) do
    case Process.whereis(nombre_registrado) do
      nil ->
        {:error, :proceso_no_existe}

      pid_anterior ->
        Process.exit(pid_anterior, :kill)
        esperar_reinicio(nombre_registrado, pid_anterior, 20)
    end
  end

  # Recursiva: revisa cada 50 ms si el proceso ya tiene un PID nuevo.
  defp esperar_reinicio(_nombre, _pid_anterior, 0), do: {:error, :no_reiniciado}

  defp esperar_reinicio(nombre, pid_anterior, intentos) do
    Process.sleep(50)

    case Process.whereis(nombre) do
      nil -> esperar_reinicio(nombre, pid_anterior, intentos - 1)
      ^pid_anterior -> esperar_reinicio(nombre, pid_anterior, intentos - 1)
      pid_nuevo -> {:ok, pid_anterior, pid_nuevo}
    end
  end
end
