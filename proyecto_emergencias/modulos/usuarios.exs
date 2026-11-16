defmodule Usuarios do
  @moduledoc """
  Registro, autenticación, conexión/desconexión, permisos por rol y actividad de usuarios.

  Estructuras usadas:
  - Mapa usuario => datos del usuario (búsqueda directa por nombre de usuario).
  - MapSet con los usuarios conectados (un usuario no puede aparecer dos veces).
  """

  @roles [:ciudadano, :voluntario, :coordinador, :administrador]

  # Usuario administrador que se crea la primera vez que se ejecuta el sistema.
  # (Decisión del equipo: un administrador no puede auto-registrarse con "connect".)
  @admin_usuario "admin"
  @admin_contrasena "admin123"

  @todos [:ciudadano, :voluntario, :coordinador, :administrador]
  @voluntario_o_mas [:voluntario, :coordinador, :administrador]
  @coordinador_o_mas [:coordinador, :administrador]
  @solo_admin [:administrador]

  # Matriz de permisos: acción => roles que pueden ejecutarla.
  # Cada acción corresponde a un comando de la interfaz (ver Interfaz @comandos).
  @permisos %{
    # Zonas
    consultar_zona: @todos,
    registrar_zona: @coordinador_o_mas,
    registrar_sector: @coordinador_o_mas,
    registrar_punto: @coordinador_o_mas,
    # Necesidades
    registrar_necesidad: @todos,
    listar_necesidades: @todos,
    necesidades_pendientes: @voluntario_o_mas,
    asignar_recurso: @coordinador_o_mas,
    cambiar_estado_necesidad: @coordinador_o_mas,
    # Recursos
    listar_recursos: @todos,
    registrar_recurso: @voluntario_o_mas,
    movimiento_inventario: @voluntario_o_mas,
    transferir_recurso: @coordinador_o_mas,
    # Personas y mensajes
    reportar_persona: @todos,
    buscar_persona: @todos,
    enviar_mensaje: @todos,
    listar_mensajes: @todos,
    cambiar_estado_persona: @voluntario_o_mas,
    marcar_mensaje: @voluntario_o_mas,
    # Mascotas
    reportar_mascota: @todos,
    listar_mascotas: @todos,
    buscar_coincidencias: @voluntario_o_mas,
    confirmar_coincidencia: @voluntario_o_mas,
    # Albergues
    consultar_albergue: @todos,
    registrar_ingreso: @voluntario_o_mas,
    registrar_salida: @voluntario_o_mas,
    registrar_albergue: @coordinador_o_mas,
    # Reportes
    resumen: @coordinador_o_mas,
    recursos_criticos: @coordinador_o_mas,
    # Concurrencia
    demo_concurrencia: @coordinador_o_mas,
    # Administración
    ver_actividad: @solo_admin
  }

  def roles, do: @roles
  def permisos, do: @permisos

  # ---------------------------------------------------------------
  # Carga y guardado
  # ---------------------------------------------------------------

  def cargar, do: Persistencia.cargar_usuarios()
  def guardar(usuarios), do: Persistencia.guardar_usuarios(usuarios)

  # Si no existe ningún administrador, se crea el administrador por defecto.
  def asegurar_administrador(usuarios) do
    hay_admin = Enum.any?(Map.values(usuarios), fn u -> u.rol == :administrador end)

    if hay_admin do
      usuarios
    else
      admin = %{
        usuario: @admin_usuario,
        contrasena: cifrar(@admin_contrasena),
        nombre: "Administrador del sistema",
        rol: :administrador,
        zona: "general"
      }

      Map.put(usuarios, @admin_usuario, admin)
    end
  end

  # ---------------------------------------------------------------
  # Registro y autenticación
  # ---------------------------------------------------------------

  # Las contraseñas no se guardan en texto claro: se guarda su resumen SHA-256.
  def cifrar(contrasena) do
    :crypto.hash(:sha256, contrasena) |> Base.encode16(case: :lower)
  end

  def existe?(usuarios, usuario), do: Map.has_key?(usuarios, usuario)

  # Registra un usuario nuevo. Devuelve {:ok, usuarios_actualizados, usuario} o {:error, motivo}.
  def registrar_usuario(usuarios, usuario, contrasena, nombre, rol, zona) do
    with {:ok, usuario} <- validar_nombre_usuario(usuario),
         {:ok, contrasena} <- Utilidades.texto_requerido(contrasena, :contrasena_vacia),
         {:ok, nombre} <- Utilidades.texto_requerido(nombre, :nombre_vacio),
         {:ok, rol} <- Utilidades.a_opcion(rol, @roles, :rol_invalido),
         {:ok, zona} <- Utilidades.texto_requerido(zona, :zona_vacia),
         :ok <- validar_no_repetido(usuarios, usuario) do
      nuevo = %{usuario: usuario, contrasena: cifrar(contrasena), nombre: nombre, rol: rol, zona: zona}
      {:ok, Map.put(usuarios, usuario, nuevo), nuevo}
    end
  end

  # Registro automático al usar "connect" con un usuario que no existe.
  # No se permite auto-registrarse como administrador.
  def registrar_automatico(usuarios, usuario, contrasena, nombre, rol, zona) do
    case Utilidades.a_opcion(rol, @roles, :rol_invalido) do
      {:ok, :administrador} -> {:error, :rol_no_permitido}
      {:ok, rol_valido} -> registrar_usuario(usuarios, usuario, contrasena, nombre, rol_valido, zona)
      error -> error
    end
  end

  # Valida la contraseña de un usuario existente.
  def autenticar(usuarios, usuario, contrasena) do
    case Map.get(usuarios, usuario) do
      nil -> {:error, :usuario_no_existe}
      datos -> if datos.contrasena == cifrar(contrasena), do: {:ok, datos}, else: {:error, :contrasena_incorrecta}
    end
  end

  defp validar_nombre_usuario(usuario) do
    case Utilidades.texto_requerido(usuario, :usuario_vacio) do
      {:ok, texto} -> if String.contains?(texto, " "), do: {:error, :usuario_con_espacios}, else: {:ok, texto}
      error -> error
    end
  end

  defp validar_no_repetido(usuarios, usuario) do
    if existe?(usuarios, usuario), do: {:error, :usuario_repetido}, else: :ok
  end

  # ---------------------------------------------------------------
  # Conexión y desconexión (connect / disconnect)
  # ---------------------------------------------------------------

  # Regla del enunciado:
  # - Si el usuario existe se valida la contraseña.
  # - Si no existe se registra automáticamente con los datos de registro recibidos.
  # datos_registro = %{nombre: ..., rol: ..., zona: ...}  (solo se usa si el usuario es nuevo)
  # Devuelve {:ok, usuarios, conectados, usuario, :autenticado | :registrado} o {:error, motivo}.
  def conectar(usuarios, conectados, usuario, contrasena, datos_registro) do
    if existe?(usuarios, usuario) do
      case autenticar(usuarios, usuario, contrasena) do
        {:ok, datos} -> {:ok, usuarios, MapSet.put(conectados, usuario), datos, :autenticado}
        error -> error
      end
    else
      case registrar_automatico(usuarios, usuario, contrasena, datos_registro.nombre, datos_registro.rol, datos_registro.zona) do
        {:ok, usuarios_nuevos, datos} -> {:ok, usuarios_nuevos, MapSet.put(conectados, usuario), datos, :registrado}
        error -> error
      end
    end
  end

  def desconectar(conectados, usuario) do
    if MapSet.member?(conectados, usuario) do
      {:ok, MapSet.delete(conectados, usuario)}
    else
      {:error, :usuario_no_conectado}
    end
  end

  # ---------------------------------------------------------------
  # Permisos
  # ---------------------------------------------------------------

  def tiene_permiso?(%{rol: rol}, accion) do
    roles_permitidos = Map.get(@permisos, accion, [])
    rol in roles_permitidos
  end

  def autorizar(usuario, accion) do
    if tiene_permiso?(usuario, accion), do: :ok, else: {:error, :sin_permiso}
  end

  # ---------------------------------------------------------------
  # Actividad (la escribe el proceso independiente ProcesoActividad)
  # ---------------------------------------------------------------

  def registrar_actividad(usuario, accion), do: ProcesoActividad.registrar(usuario, accion)

  # Si se indica un usuario, solo se devuelve su actividad.
  def consultar_actividad(usuario \\ "") do
    actividad = ProcesoActividad.consultar()

    if usuario == "" do
      actividad
    else
      Enum.filter(actividad, fn a -> a.usuario == usuario end)
    end
  end
end
