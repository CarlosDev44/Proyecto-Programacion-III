defmodule MensajesFamiliares do
  @moduledoc """
  Mensajes para facilitar la comunicación entre familiares.

  Mensaje:
      %{id: "MSG001", fecha: "...", remitente: "ana", tipo_destinatario: :persona,
        destinatario: "1094", contenido: "Estoy bien...", estado: :pendiente}

  - tipo_destinatario :persona -> destinatario es el documento de una persona registrada.
  - tipo_destinatario :familia -> destinatario es un texto libre (ej. "familia_gomez").
  """

  @estados [:pendiente, :entregado]
  @tipos_destinatario [:persona, :familia]

  def cargar, do: Persistencia.cargar_mensajes()
  def guardar(mensajes), do: Persistencia.guardar_mensajes(mensajes)

  def registrar_mensaje(mensajes, personas, remitente, tipo_destinatario, destinatario, contenido) do
    with {:ok, tipo} <- Utilidades.a_opcion(tipo_destinatario, @tipos_destinatario, :tipo_destinatario_invalido),
         {:ok, destinatario} <- Utilidades.texto_requerido(destinatario, :destinatario_vacio),
         :ok <- validar_destinatario(personas, tipo, destinatario),
         {:ok, contenido} <- Utilidades.texto_requerido(contenido, :contenido_vacio) do
      mensaje = %{
        id: Utilidades.generar_id(Enum.map(mensajes, fn m -> m.id end), "MSG"),
        fecha: Utilidades.fecha_actual(),
        remitente: remitente,
        tipo_destinatario: tipo,
        destinatario: destinatario,
        contenido: contenido,
        estado: :pendiente
      }

      {:ok, mensajes ++ [mensaje], mensaje}
    end
  end

  # Si el mensaje es para una persona, esa persona debe estar registrada.
  defp validar_destinatario(personas, :persona, documento) do
    case Personas.buscar_por_documento(personas, documento) do
      {:ok, _persona} -> :ok
      error -> error
    end
  end

  defp validar_destinatario(_personas, :familia, _destinatario), do: :ok

  def listar_mensajes(mensajes, destinatario) do
    Enum.filter(mensajes, fn m -> m.destinatario == destinatario end)
  end

  # Marca un mensaje como :entregado o :pendiente.
  def marcar_estado(mensajes, id, nuevo_estado) do
    with {:ok, estado} <- Utilidades.a_opcion(nuevo_estado, @estados, :estado_invalido),
         {:ok, mensaje} <- buscar(mensajes, id) do
      if mensaje.estado == estado do
        {:error, :mensaje_ya_tiene_ese_estado}
      else
        actualizado = %{mensaje | estado: estado}
        {:ok, Enum.map(mensajes, fn m -> if m.id == id, do: actualizado, else: m end), actualizado}
      end
    end
  end

  def buscar(mensajes, id) do
    case Enum.find(mensajes, fn m -> m.id == id end) do
      nil -> {:error, :mensaje_no_existe}
      mensaje -> {:ok, mensaje}
    end
  end
end
