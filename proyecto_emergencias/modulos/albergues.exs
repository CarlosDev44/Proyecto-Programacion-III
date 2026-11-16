defmodule Albergues do
  @moduledoc """
  Funciones puras sobre la lista de albergues.
  El estado compartido lo mantiene el GenServer ServidorAlbergues, que usa estas funciones.

  Albergue:
      %{codigo: "A01", nombre: "Albergue Norte", zona: "zona_norte", capacidad: 150,
        ocupacion: 20, personas: MapSet.new(["1094", "2033"])}

  - ocupacion: número de personas alojadas (incluye la ocupación inicial registrada).
  - personas: MapSet con los documentos registrados con register_entry
    (un MapSet impide que la misma persona quede registrada dos veces).
  """

  # datos = %{codigo, nombre, zona, capacidad, ocupacion}
  def registrar_albergue(albergues, datos) do
    with {:ok, codigo} <- Utilidades.texto_requerido(datos.codigo, :codigo_vacio),
         {:error, :albergue_no_existe} <- buscar(albergues, codigo),
         {:ok, nombre} <- Utilidades.texto_requerido(datos.nombre, :nombre_vacio),
         {:ok, zona} <- Utilidades.texto_requerido(datos.zona, :zona_vacia),
         {:ok, capacidad} <- Utilidades.a_cantidad(datos.capacidad),
         {:ok, ocupacion} <- Utilidades.a_cantidad(datos.ocupacion) do
      if ocupacion > capacidad do
        {:error, :capacidad_superada}
      else
        albergue = %{codigo: codigo, nombre: nombre, zona: zona, capacidad: capacidad, ocupacion: ocupacion, personas: MapSet.new()}
        {:ok, albergues ++ [albergue], albergue}
      end
    else
      {:ok, %{codigo: _}} -> {:error, :codigo_repetido}
      error -> error
    end
  end

  def buscar(albergues, codigo) do
    case Enum.find(albergues, fn a -> a.codigo == codigo end) do
      nil -> {:error, :albergue_no_existe}
      albergue -> {:ok, albergue}
    end
  end

  # Ingreso de una persona: se valida la capacidad ANTES de modificar.
  def registrar_ingreso(albergues, codigo, documento) do
    with {:ok, documento} <- Utilidades.texto_requerido(documento, :documento_vacio),
         {:ok, albergue} <- buscar(albergues, codigo) do
      cond do
        MapSet.member?(albergue.personas, documento) ->
          {:error, :persona_ya_en_albergue}

        albergue.ocupacion >= albergue.capacidad ->
          {:error, :capacidad_superada}

        true ->
          actualizado = %{albergue | ocupacion: albergue.ocupacion + 1, personas: MapSet.put(albergue.personas, documento)}
          {:ok, reemplazar(albergues, actualizado), actualizado}
      end
    end
  end

  def registrar_salida(albergues, codigo, documento) do
    with {:ok, albergue} <- buscar(albergues, codigo) do
      if MapSet.member?(albergue.personas, documento) do
        actualizado = %{albergue | ocupacion: albergue.ocupacion - 1, personas: MapSet.delete(albergue.personas, documento)}
        {:ok, reemplazar(albergues, actualizado), actualizado}
      else
        {:error, :persona_no_esta_en_albergue}
      end
    end
  end

  def cupos_disponibles(albergue), do: albergue.capacidad - albergue.ocupacion

  # Porcentaje de ocupación (0 si la capacidad es 0).
  def calcular_ocupacion(albergue) do
    if albergue.capacidad == 0 do
      0.0
    else
      Float.round(albergue.ocupacion * 100 / albergue.capacidad, 1)
    end
  end

  # Reporte de albergues ordenado de mayor a menor nivel de ocupación.
  def reporte_ocupacion(albergues) do
    albergues
    |> Enum.map(fn a -> Map.merge(a, %{porcentaje: calcular_ocupacion(a), cupos: cupos_disponibles(a)}) end)
    |> Enum.sort_by(fn a -> a.porcentaje end, :desc)
  end

  defp reemplazar(albergues, nuevo) do
    Enum.map(albergues, fn a -> if a.codigo == nuevo.codigo, do: nuevo, else: a end)
  end
end
