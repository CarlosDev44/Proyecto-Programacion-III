defmodule Utilidades do
  @moduledoc """
  Funciones de apoyo usadas por varios módulos:
  validar entradas del usuario, generar identificadores y obtener la fecha actual.
  Se creó este módulo para no repetir las mismas validaciones en cada módulo de dominio.
  """

  # ---------------------------------------------------------------
  # Conversión de textos a opciones válidas (átomos)
  # ---------------------------------------------------------------

  # Recibe un texto (o un átomo) y verifica que sea una de las opciones permitidas.
  # Ejemplo: a_opcion("Crítica", [:critica, :alta], :prioridad_invalida) -> {:ok, :critica}
  def a_opcion(valor, opciones, motivo_error) when is_atom(valor) do
    if valor in opciones do
      {:ok, valor}
    else
      {:error, motivo_error}
    end
  end

  def a_opcion(valor, opciones, motivo_error) when is_binary(valor) do
    texto = normalizar(valor) |> String.replace(" ", "_")
    buscar_opcion(opciones, texto, motivo_error)
  end

  def a_opcion(_valor, _opciones, motivo_error), do: {:error, motivo_error}

  # Recorre recursivamente la lista de opciones comparando su nombre con el texto.
  defp buscar_opcion([], _texto, motivo_error), do: {:error, motivo_error}

  defp buscar_opcion([opcion | resto], texto, motivo_error) do
    if Atom.to_string(opcion) == texto do
      {:ok, opcion}
    else
      buscar_opcion(resto, texto, motivo_error)
    end
  end

  # ---------------------------------------------------------------
  # Números
  # ---------------------------------------------------------------

  # Convierte un texto a entero. Devuelve {:error, :numero_invalido} si no es un número.
  def a_entero(valor) when is_integer(valor), do: {:ok, valor}

  def a_entero(valor) when is_binary(valor) do
    case Integer.parse(String.trim(valor)) do
      {numero, ""} -> {:ok, numero}
      _ -> {:error, :numero_invalido}
    end
  end

  def a_entero(_valor), do: {:error, :numero_invalido}

  # Cantidad que puede ser cero pero nunca negativa (inventarios, capacidades, ocupación).
  def a_cantidad(valor) do
    case a_entero(valor) do
      {:ok, numero} when numero >= 0 -> {:ok, numero}
      {:ok, _negativo} -> {:error, :cantidad_negativa}
      error -> error
    end
  end

  # Cantidad que debe ser mayor que cero (entradas, salidas, asignaciones, transferencias).
  def a_cantidad_positiva(valor) do
    case a_entero(valor) do
      {:ok, numero} when numero > 0 -> {:ok, numero}
      {:ok, 0} -> {:error, :cantidad_cero}
      {:ok, _negativo} -> {:error, :cantidad_negativa}
      error -> error
    end
  end

  # ---------------------------------------------------------------
  # Textos
  # ---------------------------------------------------------------

  # Verifica que un texto no esté vacío. Devuelve el texto sin espacios a los lados.
  def texto_requerido(valor, motivo_error) when is_binary(valor) do
    texto = String.trim(valor)

    if texto == "" do
      {:error, motivo_error}
    else
      {:ok, texto}
    end
  end

  def texto_requerido(_valor, motivo_error), do: {:error, motivo_error}

  # Pasa a minúsculas y quita tildes para poder comparar textos escritos por usuarios.
  def normalizar(texto) when is_binary(texto) do
    texto
    |> String.trim()
    |> String.downcase()
    |> String.replace("á", "a")
    |> String.replace("é", "e")
    |> String.replace("í", "i")
    |> String.replace("ó", "o")
    |> String.replace("ú", "u")
    |> String.replace("ñ", "n")
  end

  def normalizar(otro), do: normalizar(to_string(otro))

  # ---------------------------------------------------------------
  # Identificadores y fechas
  # ---------------------------------------------------------------

  # Genera el siguiente identificador con un prefijo. Ejemplo: ["N001", "N002"] -> "N003"
  def generar_id(ids_existentes, prefijo) do
    siguiente = mayor_numero(ids_existentes, prefijo, 0) + 1
    prefijo <> String.pad_leading(Integer.to_string(siguiente), 3, "0")
  end

  # Función recursiva: busca el mayor número usado en los identificadores.
  # Caso base: lista vacía -> se devuelve el mayor encontrado hasta ahora.
  # Caso recursivo: se compara el número del primer id y se sigue con el resto.
  defp mayor_numero([], _prefijo, mayor), do: mayor

  defp mayor_numero([id | resto], prefijo, mayor) do
    numero =
      case Integer.parse(String.replace_prefix(id, prefijo, "")) do
        {n, ""} -> n
        _ -> 0
      end

    mayor_numero(resto, prefijo, max(numero, mayor))
  end

  # Fecha y hora actual en formato "AAAA-MM-DD HH:MM:SS".
  def fecha_actual do
    NaiveDateTime.local_now()
    |> NaiveDateTime.truncate(:second)
    |> NaiveDateTime.to_string()
  end
end
