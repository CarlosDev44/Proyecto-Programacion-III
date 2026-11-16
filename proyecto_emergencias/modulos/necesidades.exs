defmodule Necesidades do
  @moduledoc """
  Gestión de necesidades puntuales (solicitudes de ayuda).

  Cada necesidad es un mapa:
      %{id: "N001", tipo: :agua, descripcion: "...", cantidad: 30, asignada: 0,
        zona: "centro", prioridad: :critica, responsable: "laura", estado: :pendiente,
        tipo_beneficiario: :zona, beneficiario: "centro", fecha: "..."}

  La prioridad se usa para ORDENAR las solicitudes: crítica > alta > media > baja.
  """

  @tipos [:agua, :alimentos, :medicamentos, :primeros_auxilios, :refugio, :transporte, :rescate, :otra]
  @prioridades [:critica, :alta, :media, :baja]
  @estados [:pendiente, :asignada, :en_atencion, :atendida, :cancelada]
  @beneficiarios [:persona, :familia, :albergue, :zona]

  # Transiciones válidas de estado. :atendida y :cancelada son estados finales (cerrada).
  @transiciones %{
    pendiente: [:asignada, :en_atencion, :cancelada],
    asignada: [:en_atencion, :atendida, :cancelada],
    en_atencion: [:atendida, :cancelada],
    atendida: [],
    cancelada: []
  }

  # Solo en estos estados una necesidad puede recibir (consumir) recursos.
  @estados_que_reciben_recursos [:pendiente, :asignada]

  def tipos, do: @tipos
  def prioridades, do: @prioridades
  def estados, do: @estados
  def beneficiarios, do: @beneficiarios

  def cargar, do: Persistencia.cargar_necesidades()
  def guardar(necesidades), do: Persistencia.guardar_necesidades(necesidades)

  # ---------------------------------------------------------------
  # Registro
  # ---------------------------------------------------------------

  # datos = %{tipo, cantidad, prioridad, zona, descripcion, responsable, tipo_beneficiario, beneficiario}
  # Devuelve {:ok, necesidades_actualizadas, necesidad} o {:error, motivo}.
  def registrar_necesidad(necesidades, zonas, datos) do
    with {:ok, tipo} <- Utilidades.a_opcion(datos.tipo, @tipos, :tipo_invalido),
         {:ok, cantidad} <- Utilidades.a_cantidad_positiva(datos.cantidad),
         {:ok, prioridad} <- Utilidades.a_opcion(datos.prioridad, @prioridades, :prioridad_invalida),
         :ok <- Zonas.validar_zona(zonas, datos.zona),
         {:ok, descripcion} <- Utilidades.texto_requerido(datos.descripcion, :descripcion_vacia),
         {:ok, tipo_b} <- Utilidades.a_opcion(datos.tipo_beneficiario, @beneficiarios, :beneficiario_invalido),
         {:ok, beneficiario} <- Utilidades.texto_requerido(datos.beneficiario, :beneficiario_vacio) do
      necesidad = %{
        id: Utilidades.generar_id(ids(necesidades), "N"),
        tipo: tipo,
        descripcion: descripcion,
        cantidad: cantidad,
        asignada: 0,
        zona: datos.zona,
        prioridad: prioridad,
        responsable: datos.responsable,
        estado: :pendiente,
        tipo_beneficiario: tipo_b,
        beneficiario: beneficiario,
        fecha: Utilidades.fecha_actual()
      }

      {:ok, necesidades ++ [necesidad], necesidad}
    end
  end

  defp ids(necesidades), do: Enum.map(necesidades, fn n -> n.id end)

  # ---------------------------------------------------------------
  # Consultas
  # ---------------------------------------------------------------

  def buscar(necesidades, id) do
    case Enum.find(necesidades, fn n -> n.id == id end) do
      nil -> {:error, :necesidad_no_existe}
      necesidad -> {:ok, necesidad}
    end
  end

  # Filtra por zona, tipo, prioridad y/o estado y devuelve el resultado ordenado por prioridad.
  # filtros es un mapa con textos, por ejemplo: %{"zona" => "centro", "prioridad" => "critica"}
  def filtrar(necesidades, filtros) do
    filtradas =
      Enum.filter(necesidades, fn n ->
        Enum.all?(filtros, fn {campo, valor} -> cumple_filtro?(n, campo, valor) end)
      end)

    ordenar_por_prioridad(filtradas)
  end

  defp cumple_filtro?(necesidad, "zona", valor), do: necesidad.zona == valor
  defp cumple_filtro?(necesidad, "tipo", valor), do: Atom.to_string(necesidad.tipo) == Utilidades.normalizar(valor)
  defp cumple_filtro?(necesidad, "prioridad", valor), do: Atom.to_string(necesidad.prioridad) == Utilidades.normalizar(valor)
  defp cumple_filtro?(necesidad, "estado", valor), do: Atom.to_string(necesidad.estado) == Utilidades.normalizar(valor)
  defp cumple_filtro?(_necesidad, _campo_desconocido, _valor), do: true

  # Valor numérico de cada prioridad: menor número = se atiende primero.
  def peso_prioridad(:critica), do: 1
  def peso_prioridad(:alta), do: 2
  def peso_prioridad(:media), do: 3
  def peso_prioridad(:baja), do: 4

  # Ordena por prioridad y, a igual prioridad, por identificador (la más antigua primero).
  def ordenar_por_prioridad(necesidades) do
    Enum.sort_by(necesidades, fn n -> {peso_prioridad(n.prioridad), n.id} end)
  end

  def cerrada?(necesidad), do: necesidad.estado in [:atendida, :cancelada]

  # Necesidades que aún no se han cerrado, ordenadas por prioridad (comando pending_needs).
  def pendientes(necesidades) do
    abiertas = Enum.reject(necesidades, fn n -> cerrada?(n) end)
    ordenar_por_prioridad(abiertas)
  end

  # Selecciona la necesidad pendiente más prioritaria (la próxima que se debe atender).
  def siguiente_a_atender(necesidades) do
    candidatas = Enum.filter(necesidades, fn n -> n.estado == :pendiente end)

    case ordenar_por_prioridad(candidatas) do
      [] -> {:error, :sin_necesidades_pendientes}
      [primera | _] -> {:ok, primera}
    end
  end

  def cantidad_faltante(necesidad), do: necesidad.cantidad - necesidad.asignada

  # ---------------------------------------------------------------
  # Asignación de recursos
  # ---------------------------------------------------------------

  # Verifica que la necesidad pueda recibir la cantidad indicada.
  # Una necesidad atendida o cancelada NO puede volver a consumir recursos.
  def validar_asignacion(necesidades, id, cantidad) do
    with {:ok, necesidad} <- buscar(necesidades, id),
         :ok <- validar_estado_para_asignar(necesidad),
         {:ok, cantidad} <- Utilidades.a_cantidad_positiva(cantidad) do
      if cantidad <= cantidad_faltante(necesidad) do
        {:ok, necesidad}
      else
        {:error, :cantidad_excede_necesidad}
      end
    end
  end

  defp validar_estado_para_asignar(necesidad) do
    cond do
      necesidad.estado == :atendida -> {:error, :necesidad_ya_atendida}
      necesidad.estado == :cancelada -> {:error, :necesidad_cancelada}
      necesidad.estado in @estados_que_reciben_recursos -> :ok
      true -> {:error, :estado_no_permite_asignar}
    end
  end

  # Actualiza la necesidad después de que el inventario confirmó la asignación.
  def registrar_asignacion(necesidades, id, cantidad) do
    Enum.map(necesidades, fn n ->
      if n.id == id do
        %{n | asignada: n.asignada + cantidad, estado: :asignada}
      else
        n
      end
    end)
  end

  # Flujo completo de assign_resource:
  # 1. Validar la necesidad.  2. Pedir al GenServer de inventario que descuente.
  # 3. Si el inventario confirma, actualizar la necesidad.
  # Si cantidad es nil se asigna lo que le falta a la necesidad.
  def asignar_recurso(necesidades, id, referencia_recurso, cantidad, usuario) do
    cantidad_final =
      case {cantidad, buscar(necesidades, id)} do
        {nil, {:ok, necesidad}} -> cantidad_faltante(necesidad)
        _ -> cantidad
      end

    # La cantidad puede llegar como texto desde la consola ("20"): se convierte a número primero.
    with {:ok, cantidad_numero} <- Utilidades.a_cantidad_positiva(cantidad_final),
         {:ok, _necesidad} <- validar_asignacion(necesidades, id, cantidad_numero),
         {:ok, asignacion} <- ServidorInventario.asignar(referencia_recurso, cantidad_numero, id, usuario) do
      {:ok, registrar_asignacion(necesidades, id, asignacion.cantidad), asignacion}
    end
  end

  # ---------------------------------------------------------------
  # Cambio de estado
  # ---------------------------------------------------------------

  def cambiar_estado(necesidades, id, nuevo_estado) do
    with {:ok, necesidad} <- buscar(necesidades, id),
         {:ok, nuevo} <- Utilidades.a_opcion(nuevo_estado, @estados, :estado_invalido),
         :ok <- validar_transicion(necesidad.estado, nuevo) do
      actualizada = %{necesidad | estado: nuevo}
      lista = Enum.map(necesidades, fn n -> if n.id == id, do: actualizada, else: n end)
      {:ok, lista, actualizada}
    end
  end

  # No se puede cerrar dos veces una necesidad y solo se permiten las transiciones definidas.
  def validar_transicion(actual, nuevo) do
    cond do
      actual in [:atendida, :cancelada] -> {:error, :necesidad_ya_cerrada}
      nuevo in Map.get(@transiciones, actual, []) -> :ok
      true -> {:error, :transicion_invalida}
    end
  end
end
