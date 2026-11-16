defmodule SimuladorUsuarios do
  @moduledoc """
  Simula varios usuarios trabajando al mismo tiempo usando procesos básicos
  (spawn, send y receive). Cada "usuario" es un proceso que hace su solicitud al
  GenServer correspondiente y envía el resultado de vuelta al proceso que lo creó.
  """

  # Ejecuta varias tareas al mismo tiempo, una por proceso.
  # tareas = [{etiqueta, funcion_sin_argumentos}, ...]
  # Devuelve [{etiqueta, resultado}, ...] en el orden en que terminaron.
  def ejecutar_en_paralelo(tareas) do
    padre = self()
    referencia = make_ref()
    lanzar(tareas, padre, referencia)
    recolectar(length(tareas), referencia, [])
  end

  # Recursiva: crea un proceso por cada tarea.
  defp lanzar([], _padre, _referencia), do: :ok

  defp lanzar([{etiqueta, funcion} | resto], padre, referencia) do
    spawn(fn ->
      resultado = funcion.()
      send(padre, {:resultado, referencia, etiqueta, resultado})
    end)

    lanzar(resto, padre, referencia)
  end

  # Recursiva: espera tantos mensajes como procesos se lanzaron.
  defp recolectar(0, _referencia, resultados), do: Enum.reverse(resultados)

  defp recolectar(faltantes, referencia, resultados) do
    receive do
      {:resultado, ^referencia, etiqueta, resultado} ->
        recolectar(faltantes - 1, referencia, [{etiqueta, resultado} | resultados])
    after
      5000 -> Enum.reverse(resultados)
    end
  end

  # ---------------------------------------------------------------
  # Demostración del conflicto de inventario
  # ---------------------------------------------------------------

  # Varias necesidades piden el MISMO recurso al mismo tiempo (cada una lo que le falta).
  # Devuelve {necesidades_actualizadas, resultados}.
  def asignar_en_paralelo(necesidades, referencia_recurso, ids_necesidades, usuario) do
    ids = Enum.uniq(ids_necesidades)

    # Primero se valida cada necesidad (existe, no está atendida, etc.).
    {validas, invalidas} =
      Enum.reduce(ids, {[], []}, fn id, {ok, error} ->
        case Necesidades.buscar(necesidades, id) do
          {:ok, n} ->
            faltante = Necesidades.cantidad_faltante(n)

            case Necesidades.validar_asignacion(necesidades, id, faltante) do
              {:ok, _} -> {ok ++ [{id, faltante}], error}
              {:error, motivo} -> {ok, error ++ [{id, {:error, motivo}}]}
            end

          {:error, motivo} ->
            {ok, error ++ [{id, {:error, motivo}}]}
        end
      end)

    # Un proceso por necesidad: todos llaman al GenServer a la vez.
    tareas =
      Enum.map(validas, fn {id, cantidad} ->
        {id, fn -> ServidorInventario.asignar(referencia_recurso, cantidad, id, usuario) end}
      end)

    resultados = ejecutar_en_paralelo(tareas)

    # Solo las asignaciones confirmadas por el GenServer modifican las necesidades.
    actualizadas =
      Enum.reduce(resultados, necesidades, fn
        {id, {:ok, asignacion}}, lista -> Necesidades.registrar_asignacion(lista, id, asignacion.cantidad)
        _, lista -> lista
      end)

    {actualizadas, resultados ++ invalidas}
  end

  # ---------------------------------------------------------------
  # Demostración del conflicto de capacidad en albergues
  # ---------------------------------------------------------------

  # Varias personas intentan ingresar al mismo albergue al mismo tiempo.
  def ingresar_en_paralelo(codigo_albergue, documentos) do
    tareas =
      Enum.map(documentos, fn doc ->
        {doc, fn -> ServidorAlbergues.registrar_ingreso(codigo_albergue, doc) end}
      end)

    ejecutar_en_paralelo(tareas)
  end
end
