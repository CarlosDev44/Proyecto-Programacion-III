defmodule Personas do
  @moduledoc """
  Registro y búsqueda de personas afectadas, con historial de cambios de estado.

  Persona:
      %{id: "P001", documento: "1094", nombre: "Andrés", edad: 30, zona: "centro",
        estado: :localizada,
        historial: [%{fecha: "...", anterior: "nuevo", nuevo: "localizada", usuario: "ana"}]}
  """

  @estados [:sin_informacion, :reportada, :localizada, :trasladada, :en_albergue, :reunificada]

  # Transiciones válidas. :reunificada es el estado final (el caso queda resuelto).
  @transiciones %{
    sin_informacion: [:reportada, :localizada],
    reportada: [:localizada, :sin_informacion],
    localizada: [:trasladada, :en_albergue, :reunificada],
    trasladada: [:localizada, :en_albergue, :reunificada],
    en_albergue: [:trasladada, :reunificada],
    reunificada: []
  }

  def estados, do: @estados

  def cargar, do: Persistencia.cargar_personas()
  def guardar(personas), do: Persistencia.guardar_personas(personas)

  # datos = %{documento, nombre, edad, zona, estado, usuario}
  def registrar_persona(personas, zonas, datos) do
    with {:ok, documento} <- Utilidades.texto_requerido(datos.documento, :documento_vacio),
         {:error, :persona_no_existe} <- buscar_por_documento(personas, documento),
         {:ok, nombre} <- Utilidades.texto_requerido(datos.nombre, :nombre_vacio),
         {:ok, edad} <- validar_edad(datos.edad),
         :ok <- Zonas.validar_zona(zonas, datos.zona),
         {:ok, estado} <- Utilidades.a_opcion(datos.estado, @estados, :estado_invalido) do
      persona = %{
        id: Utilidades.generar_id(Enum.map(personas, fn p -> p.id end), "P"),
        documento: documento,
        nombre: nombre,
        edad: edad,
        zona: datos.zona,
        estado: estado,
        historial: [crear_historial("nuevo", estado, datos.usuario)]
      }

      {:ok, personas ++ [persona], persona}
    else
      {:ok, %{documento: _}} -> {:error, :documento_repetido}
      error -> error
    end
  end

  defp validar_edad(edad) do
    case Utilidades.a_cantidad(edad) do
      {:ok, numero} when numero <= 120 -> {:ok, numero}
      {:ok, _} -> {:error, :edad_invalida}
      error -> error
    end
  end

  defp crear_historial(anterior, nuevo, usuario) do
    %{fecha: Utilidades.fecha_actual(), anterior: to_string(anterior), nuevo: to_string(nuevo), usuario: usuario}
  end

  # ---------------------------------------------------------------
  # Búsquedas: por documento, nombre, zona o estado
  # ---------------------------------------------------------------

  def buscar_por_documento(personas, documento) do
    case Enum.find(personas, fn p -> p.documento == documento end) do
      nil -> {:error, :persona_no_existe}
      persona -> {:ok, persona}
    end
  end

  # criterio: :documento | :nombre | :zona | :estado
  # La búsqueda por nombre encuentra coincidencias parciales y no distingue mayúsculas ni tildes.
  def buscar(personas, :documento, valor), do: Enum.filter(personas, fn p -> p.documento == valor end)
  def buscar(personas, :zona, valor), do: Enum.filter(personas, fn p -> p.zona == valor end)

  def buscar(personas, :nombre, valor) do
    texto = Utilidades.normalizar(valor)
    Enum.filter(personas, fn p -> String.contains?(Utilidades.normalizar(p.nombre), texto) end)
  end

  def buscar(personas, :estado, valor) do
    case Utilidades.a_opcion(valor, @estados, :estado_invalido) do
      {:ok, estado} -> Enum.filter(personas, fn p -> p.estado == estado end)
      {:error, _} -> []
    end
  end

  def buscar(_personas, _criterio, _valor), do: []

  # ---------------------------------------------------------------
  # Cambio de estado con historial
  # ---------------------------------------------------------------

  def cambiar_estado(personas, documento, nuevo_estado, usuario) do
    with {:ok, persona} <- buscar_por_documento(personas, documento),
         {:ok, nuevo} <- Utilidades.a_opcion(nuevo_estado, @estados, :estado_invalido),
         :ok <- validar_transicion(persona.estado, nuevo) do
      actualizada = %{
        persona
        | estado: nuevo,
          historial: persona.historial ++ [crear_historial(persona.estado, nuevo, usuario)]
      }

      lista = Enum.map(personas, fn p -> if p.documento == documento, do: actualizada, else: p end)
      {:ok, lista, actualizada}
    end
  end

  def validar_transicion(actual, nuevo) do
    cond do
      actual == :reunificada -> {:error, :persona_ya_reunificada}
      nuevo in Map.get(@transiciones, actual, []) -> :ok
      true -> {:error, :transicion_invalida}
    end
  end

  # Cuando una persona registrada ingresa a un albergue se intenta pasar a :en_albergue.
  # Si no está registrada o la transición no es válida, la lista queda igual.
  def actualizar_por_ingreso_albergue(personas, documento, usuario) do
    case cambiar_estado(personas, documento, :en_albergue, usuario) do
      {:ok, lista, _persona} -> lista
      {:error, _motivo} -> personas
    end
  end
end
