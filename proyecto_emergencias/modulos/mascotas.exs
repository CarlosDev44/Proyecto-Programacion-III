defmodule Mascotas do
  @moduledoc """
  Reportes de mascotas perdidas y encontradas, y búsqueda de coincidencias.

  Reporte:
      %{id: "M001", tipo: :perdida, especie: "perro", nombre: "Luna", caracteristicas: "collar rojo",
        color: "negra", tamano: "mediana", zona: "zona_norte", contacto: "3001234567",
        estado: :activa, coincidencia: "", reportado_por: "ana"}

  ALGORITMO DE SIMILITUD (definido por el equipo):
  - Si la especie es distinta el puntaje es 0 (un perro nunca coincide con un gato).
  - Si la especie es igual se suman puntos:
      especie igual  40
      color igual    25
      tamaño igual   20
      zona igual     15
      ----------------
      máximo        100
  - Se considera "posible coincidencia" cuando el puntaje es >= 60
    (especie + al menos color, o tamaño y zona).
  """

  @tipos [:perdida, :encontrada]
  @estados [:activa, :posible_coincidencia, :resuelta]

  @peso_especie 40
  @peso_color 25
  @peso_tamano 20
  @peso_zona 15
  @umbral 60

  def umbral, do: @umbral

  def cargar, do: Persistencia.cargar_mascotas()
  def guardar(mascotas), do: Persistencia.guardar_mascotas(mascotas)

  # ---------------------------------------------------------------
  # Registro y consulta
  # ---------------------------------------------------------------

  # datos = %{tipo, especie, nombre, caracteristicas, color, tamano, zona, contacto, reportado_por}
  # tipo acepta "perdida"/"lost" y "encontrada"/"found".
  def registrar_reporte(mascotas, zonas, datos) do
    with {:ok, tipo} <- convertir_tipo(datos.tipo),
         {:ok, especie} <- Utilidades.texto_requerido(datos.especie, :especie_vacia),
         {:ok, color} <- Utilidades.texto_requerido(datos.color, :color_vacio),
         {:ok, tamano} <- Utilidades.texto_requerido(datos.tamano, :tamano_vacio),
         :ok <- Zonas.validar_zona(zonas, datos.zona),
         {:ok, contacto} <- Utilidades.texto_requerido(datos.contacto, :contacto_vacio) do
      reporte = %{
        id: Utilidades.generar_id(Enum.map(mascotas, fn m -> m.id end), "M"),
        tipo: tipo,
        especie: Utilidades.normalizar(especie),
        nombre: texto_o_desconocido(datos.nombre),
        caracteristicas: texto_o_desconocido(datos.caracteristicas),
        color: Utilidades.normalizar(color),
        tamano: Utilidades.normalizar(tamano),
        zona: datos.zona,
        contacto: contacto,
        estado: :activa,
        coincidencia: "",
        reportado_por: datos.reportado_por
      }

      {:ok, mascotas ++ [reporte], reporte}
    end
  end

  defp convertir_tipo(tipo) do
    case Utilidades.normalizar(tipo) do
      "lost" -> {:ok, :perdida}
      "found" -> {:ok, :encontrada}
      otro -> Utilidades.a_opcion(otro, @tipos, :tipo_reporte_invalido)
    end
  end

  defp texto_o_desconocido(texto) do
    if String.trim(to_string(texto)) == "", do: "desconocido", else: String.trim(texto)
  end

  def buscar(mascotas, id) do
    case Enum.find(mascotas, fn m -> m.id == id end) do
      nil -> {:error, :reporte_no_existe}
      reporte -> {:ok, reporte}
    end
  end

  # Consulta por especie, zona y/o estado. filtros = %{"especie" => "perro", "estado" => "activa"}
  def consultar(mascotas, filtros) do
    Enum.filter(mascotas, fn m ->
      Enum.all?(filtros, fn
        {"especie", valor} -> m.especie == Utilidades.normalizar(valor)
        {"zona", valor} -> m.zona == valor
        {"estado", valor} -> Atom.to_string(m.estado) == Utilidades.normalizar(valor)
        {"tipo", valor} -> Atom.to_string(m.tipo) == Utilidades.normalizar(valor)
        _ -> true
      end)
    end)
  end

  # ---------------------------------------------------------------
  # Similitud y coincidencias
  # ---------------------------------------------------------------

  def calcular_similitud(perdida, encontrada) do
    if perdida.especie != encontrada.especie do
      0
    else
      @peso_especie +
        puntos(perdida.color == encontrada.color, @peso_color) +
        puntos(perdida.tamano == encontrada.tamano, @peso_tamano) +
        puntos(perdida.zona == encontrada.zona, @peso_zona)
    end
  end

  defp puntos(true, peso), do: peso
  defp puntos(false, _peso), do: 0

  # Devuelve la lista de posibles coincidencias ordenada de mayor a menor puntaje:
  # [%{perdida: "M001", encontrada: "M002", puntaje: 100}, ...]
  def buscar_coincidencias(mascotas) do
    abiertas = Enum.reject(mascotas, fn m -> m.estado == :resuelta end)
    perdidas = Enum.filter(abiertas, fn m -> m.tipo == :perdida end)
    encontradas = Enum.filter(abiertas, fn m -> m.tipo == :encontrada end)

    comparar_perdidas(perdidas, encontradas)
    |> Enum.sort_by(fn c -> c.puntaje end, :desc)
  end

  # Función recursiva: compara cada mascota perdida con todas las encontradas.
  # Caso base: no quedan perdidas -> lista vacía.
  # Caso recursivo: coincidencias de la primera perdida + coincidencias del resto.
  defp comparar_perdidas([], _encontradas), do: []

  defp comparar_perdidas([perdida | resto], encontradas) do
    comparar_con_encontradas(perdida, encontradas) ++ comparar_perdidas(resto, encontradas)
  end

  # Función recursiva: compara una perdida con cada encontrada y guarda las que superan el umbral.
  defp comparar_con_encontradas(_perdida, []), do: []

  defp comparar_con_encontradas(perdida, [encontrada | resto]) do
    puntaje = calcular_similitud(perdida, encontrada)

    if puntaje >= @umbral do
      [%{perdida: perdida.id, encontrada: encontrada.id, puntaje: puntaje} | comparar_con_encontradas(perdida, resto)]
    else
      comparar_con_encontradas(perdida, resto)
    end
  end

  # match_pets: busca coincidencias y marca los reportes involucrados como :posible_coincidencia.
  # Devuelve {mascotas_actualizadas, coincidencias}.
  def marcar_posibles_coincidencias(mascotas) do
    coincidencias = buscar_coincidencias(mascotas)

    ids =
      Enum.reduce(coincidencias, MapSet.new(), fn c, conjunto ->
        conjunto |> MapSet.put(c.perdida) |> MapSet.put(c.encontrada)
      end)

    actualizadas =
      Enum.map(mascotas, fn m ->
        if MapSet.member?(ids, m.id) and m.estado == :activa do
          %{m | estado: :posible_coincidencia}
        else
          m
        end
      end)

    {actualizadas, coincidencias}
  end

  # Confirma la coincidencia entre una mascota perdida y una encontrada: ambos reportes se cierran.
  # Un reporte resuelto no se puede volver a resolver.
  def confirmar_coincidencia(mascotas, id_perdida, id_encontrada) do
    with {:ok, perdida} <- buscar(mascotas, id_perdida),
         {:ok, encontrada} <- buscar(mascotas, id_encontrada),
         :ok <- validar_tipos(perdida, encontrada),
         :ok <- validar_no_resuelto(perdida),
         :ok <- validar_no_resuelto(encontrada) do
      actualizadas =
        Enum.map(mascotas, fn m ->
          cond do
            m.id == id_perdida -> %{m | estado: :resuelta, coincidencia: id_encontrada}
            m.id == id_encontrada -> %{m | estado: :resuelta, coincidencia: id_perdida}
            true -> m
          end
        end)

      {:ok, actualizadas}
    end
  end

  defp validar_tipos(%{tipo: :perdida}, %{tipo: :encontrada}), do: :ok
  defp validar_tipos(_, _), do: {:error, :tipos_no_corresponden}

  defp validar_no_resuelto(%{estado: :resuelta}), do: {:error, :reporte_ya_resuelto}
  defp validar_no_resuelto(_reporte), do: :ok

  def estados, do: @estados
end
