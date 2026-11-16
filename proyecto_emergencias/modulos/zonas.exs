defmodule Zonas do
  @moduledoc """
  Gestión de zonas afectadas con la estructura jerárquica:

      zona -> sectores -> puntos de atención

  Ejemplo de una zona (mapas y listas anidadas):

      %{codigo: "centro", nombre: "Centro", nivel: :critico, personas_afectadas: 100,
        sectores: [
          %{codigo: "S1", nombre: "Sector 1", nivel: :alto, personas_afectadas: 40,
            puntos: [%{codigo: "P1", nombre: "Hospital de campaña", sector: "S1"}]}
        ]}

  Aquí están las funciones recursivas principales del proyecto:
  sumar_personas_sectores/1, contar_puntos/1, obtener_puntos/1,
  buscar_sector/2, buscar_punto/2 y sectores_por_nivel/2.
  """

  @niveles [:critico, :alto, :medio, :bajo]

  def niveles, do: @niveles

  def cargar, do: Persistencia.cargar_zonas()
  def guardar(zonas), do: Persistencia.guardar_zonas(zonas)

  # ---------------------------------------------------------------
  # Registro
  # ---------------------------------------------------------------

  # Registra una zona nueva. Devuelve {:ok, zonas_actualizadas, zona} o {:error, motivo}.
  def registrar_zona(zonas, codigo, nombre, nivel, personas) do
    with {:ok, codigo} <- Utilidades.texto_requerido(codigo, :codigo_vacio),
         {:ok, nombre} <- Utilidades.texto_requerido(nombre, :nombre_vacio),
         {:ok, nivel} <- Utilidades.a_opcion(nivel, @niveles, :nivel_invalido),
         {:ok, personas} <- Utilidades.a_cantidad(personas),
         {:error, :zona_no_existe} <- buscar_zona(zonas, codigo) do
      zona = %{codigo: codigo, nombre: nombre, nivel: nivel, personas_afectadas: personas, sectores: []}
      {:ok, zonas ++ [zona], zona}
    else
      {:ok, %{codigo: _}} -> {:error, :codigo_repetido}
      error -> error
    end
  end

  # Agrega un sector dentro de una zona existente.
  def registrar_sector(zonas, codigo_zona, codigo, nombre, nivel, personas) do
    with {:ok, zona} <- buscar_zona(zonas, codigo_zona),
         {:ok, codigo} <- Utilidades.texto_requerido(codigo, :codigo_vacio),
         {:ok, nombre} <- Utilidades.texto_requerido(nombre, :nombre_vacio),
         {:ok, nivel} <- Utilidades.a_opcion(nivel, @niveles, :nivel_invalido),
         {:ok, personas} <- Utilidades.a_cantidad(personas),
         {:error, :sector_no_existe} <- buscar_sector(zona.sectores, codigo) do
      sector = %{codigo: codigo, nombre: nombre, nivel: nivel, personas_afectadas: personas, puntos: []}
      zona_actualizada = %{zona | sectores: zona.sectores ++ [sector]}
      {:ok, reemplazar_zona(zonas, zona_actualizada), sector}
    else
      {:ok, %{codigo: _}} -> {:error, :codigo_repetido}
      error -> error
    end
  end

  # Agrega un punto de atención dentro de un sector de una zona.
  def registrar_punto(zonas, codigo_zona, codigo_sector, codigo, nombre) do
    with {:ok, zona} <- buscar_zona(zonas, codigo_zona),
         {:ok, sector} <- buscar_sector(zona.sectores, codigo_sector),
         {:ok, codigo} <- Utilidades.texto_requerido(codigo, :codigo_vacio),
         {:ok, nombre} <- Utilidades.texto_requerido(nombre, :nombre_vacio),
         {:error, :punto_no_existe} <- buscar_punto(zona.sectores, codigo) do
      punto = %{codigo: codigo, nombre: nombre, sector: sector.codigo}
      sector_actualizado = %{sector | puntos: sector.puntos ++ [punto]}
      zona_actualizada = %{zona | sectores: reemplazar_sector(zona.sectores, sector_actualizado)}
      {:ok, reemplazar_zona(zonas, zona_actualizada), punto}
    else
      {:ok, %{codigo: _}} -> {:error, :codigo_repetido}
      error -> error
    end
  end

  # ---------------------------------------------------------------
  # Consultas
  # ---------------------------------------------------------------

  def buscar_zona(zonas, codigo) do
    case Enum.find(zonas, fn z -> z.codigo == codigo end) do
      nil -> {:error, :zona_no_existe}
      zona -> {:ok, zona}
    end
  end

  # Se usa en otros módulos para asociar necesidades, recursos, albergues y reportes a una zona.
  def validar_zona(zonas, codigo) do
    case buscar_zona(zonas, codigo) do
      {:ok, _zona} -> :ok
      error -> error
    end
  end

  # Estadísticas acumuladas de una zona y sus sectores (usa las funciones recursivas).
  def estadisticas_zona(zona) do
    personas_sectores = sumar_personas_sectores(zona.sectores)

    %{
      codigo: zona.codigo,
      nombre: zona.nombre,
      nivel: zona.nivel,
      personas_zona: zona.personas_afectadas,
      personas_sectores: personas_sectores,
      personas_total: zona.personas_afectadas + personas_sectores,
      total_sectores: length(zona.sectores),
      total_puntos: contar_puntos(zona.sectores),
      puntos: obtener_puntos(zona.sectores),
      sectores_criticos: sectores_por_nivel(zona.sectores, :critico)
    }
  end

  # ---------------------------------------------------------------
  # FUNCIONES RECURSIVAS sobre la jerarquía zona -> sectores -> puntos
  # ---------------------------------------------------------------

  # 1) Suma las personas afectadas de todos los sectores.
  # Caso base: no quedan sectores -> 0.
  # Caso recursivo: personas del primer sector + suma del resto de sectores.
  def sumar_personas_sectores([]), do: 0

  def sumar_personas_sectores([sector | resto]) do
    sector.personas_afectadas + sumar_personas_sectores(resto)
  end

  # 2) Cuenta los puntos de atención de todos los sectores.
  # Caso base: no quedan sectores -> 0.
  # Caso recursivo: puntos del primer sector + puntos del resto de sectores.
  def contar_puntos([]), do: 0

  def contar_puntos([sector | resto]) do
    contar_elementos(sector.puntos) + contar_puntos(resto)
  end

  # Cuenta los elementos de una lista (recursiva, sin usar length/1).
  # Caso base: lista vacía -> 0. Caso recursivo: 1 + elementos del resto.
  defp contar_elementos([]), do: 0
  defp contar_elementos([_ | resto]), do: 1 + contar_elementos(resto)

  # 3) Obtiene en una sola lista todos los puntos de atención de los sectores.
  # Caso base: no quedan sectores -> lista vacía.
  # Caso recursivo: puntos del primer sector unidos con los puntos del resto.
  def obtener_puntos([]), do: []

  def obtener_puntos([sector | resto]) do
    sector.puntos ++ obtener_puntos(resto)
  end

  # 4) Busca un sector por su código.
  # Caso base 1: lista vacía -> no se encontró.
  # Caso base 2: el primer sector tiene el código buscado -> se devuelve.
  # Caso recursivo: se busca en el resto de la lista.
  def buscar_sector([], _codigo), do: {:error, :sector_no_existe}
  def buscar_sector([%{codigo: codigo} = sector | _resto], codigo), do: {:ok, sector}
  def buscar_sector([_sector | resto], codigo), do: buscar_sector(resto, codigo)

  # 5) Busca un punto de atención recorriendo todos los sectores (dos niveles de la jerarquía).
  # Caso base: no quedan sectores -> no se encontró.
  # Caso recursivo: se busca dentro de los puntos del primer sector; si no está, en el resto.
  def buscar_punto([], _codigo), do: {:error, :punto_no_existe}

  def buscar_punto([sector | resto], codigo) do
    case buscar_en_puntos(sector.puntos, codigo) do
      {:ok, punto} -> {:ok, punto}
      {:error, _} -> buscar_punto(resto, codigo)
    end
  end

  defp buscar_en_puntos([], _codigo), do: {:error, :punto_no_existe}
  defp buscar_en_puntos([%{codigo: codigo} = punto | _resto], codigo), do: {:ok, punto}
  defp buscar_en_puntos([_punto | resto], codigo), do: buscar_en_puntos(resto, codigo)

  # 6) Devuelve los sectores que tienen un nivel de afectación dado.
  # Caso base: lista vacía -> lista vacía.
  # Caso recursivo: si el primer sector tiene el nivel se agrega; luego se revisa el resto.
  def sectores_por_nivel([], _nivel), do: []

  def sectores_por_nivel([sector | resto], nivel) do
    if sector.nivel == nivel do
      [sector | sectores_por_nivel(resto, nivel)]
    else
      sectores_por_nivel(resto, nivel)
    end
  end

  # Reemplaza un sector (mismo código) dentro de la lista de sectores. También es recursiva.
  defp reemplazar_sector([], _sector_nuevo), do: []

  defp reemplazar_sector([sector | resto], sector_nuevo) do
    if sector.codigo == sector_nuevo.codigo do
      [sector_nuevo | resto]
    else
      [sector | reemplazar_sector(resto, sector_nuevo)]
    end
  end

  defp reemplazar_zona(zonas, zona_nueva) do
    Enum.map(zonas, fn z -> if z.codigo == zona_nueva.codigo, do: zona_nueva, else: z end)
  end
end
