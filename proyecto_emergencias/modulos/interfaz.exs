defmodule Interfaz do
  @moduledoc """
  Interfaz por consola basada en COMANDOS, como los "Comandos de referencia" del enunciado.

      connect laura 1234 coordinador centro "Laura Gómez"
      register_need agua 30 critica centro "Punto de atención sector 3"
      assign_resource N001 agua 30

  Cada línea se separa en palabras (los textos entre comillas cuentan como una sola palabra)
  y se reconoce con pattern matching en las cláusulas de despachar/4.

  La interfaz NO contiene lógica de negocio: solo interpreta el comando, verifica permisos,
  llama a las funciones de los módulos y muestra resultados o errores.

  Mantiene un mapa de estado que se pasa de una llamada a otra (ciclo recursivo):
      %{usuarios, conectados (MapSet), actual, zonas, necesidades, personas, mensajes, mascotas}
  El inventario y los albergues NO están aquí: viven en sus GenServer porque son compartidos.
  """

  # Lista de comandos: {nombre, acción de permiso, forma de uso, descripción, grupo}
  # La acción corresponde a la matriz de permisos de Usuarios (nil = no requiere conexión).
  # Son los comandos de referencia del enunciado más los mínimos necesarios para cubrir
  # requisitos que no tenían comando sugerido (sectores, estados, entradas/salidas, etc.).
  @comandos [
    {"connect", nil, "connect usuario contraseña [tipo zona \"nombre completo\"]", "Conectarse (si no existe se registra)", "Usuarios"},
    {"disconnect", nil, "disconnect", "Desconectarse", "Usuarios"},
    {"activity", :ver_actividad, "activity [usuario]", "Ver la actividad de los usuarios", "Usuarios"},
    {"register_zone", :registrar_zona, "register_zone codigo nombre nivel [personas]", "Registrar zona (nivel: critico/alto/medio/bajo)", "Zonas"},
    {"register_sector", :registrar_sector, "register_sector zona codigo nombre nivel [personas]", "Registrar sector en una zona", "Zonas"},
    {"register_point", :registrar_punto, "register_point zona sector codigo nombre", "Registrar punto de atención en un sector", "Zonas"},
    {"zone_status", :consultar_zona, "zone_status zona", "Estado general y estadísticas de una zona", "Zonas"},
    {"register_need", :registrar_necesidad, "register_need tipo cantidad prioridad zona descripcion [persona|familia|albergue referencia]", "Registrar necesidad", "Necesidades"},
    {"list_needs", :listar_necesidades, "list_needs [zona=.. tipo=.. prioridad=.. estado=..]", "Listar necesidades ordenadas por prioridad", "Necesidades"},
    {"assign_resource", :asignar_recurso, "assign_resource necesidad recurso|categoria [cantidad]", "Asignar recurso a una necesidad", "Necesidades"},
    {"need_status", :cambiar_estado_necesidad, "need_status necesidad estado", "Cambiar estado (asignada/en_atencion/atendida/cancelada)", "Necesidades"},
    {"pending_needs", :necesidades_pendientes, "pending_needs", "Necesidades abiertas por prioridad", "Necesidades"},
    {"register_resource", :registrar_recurso, "register_resource codigo categoria cantidad unidad ubicacion [zona] [\"nombre\"]", "Registrar recurso", "Recursos"},
    {"list_resources", :listar_recursos, "list_resources [categoria=.. zona=..]", "Listar recursos / disponibilidad", "Recursos"},
    {"resource_in", :movimiento_inventario, "resource_in codigo cantidad", "Registrar entrada de inventario", "Recursos"},
    {"resource_out", :movimiento_inventario, "resource_out codigo cantidad", "Registrar salida de inventario", "Recursos"},
    {"transfer_resource", :transferir_recurso, "transfer_resource codigo origen destino cantidad [zona_destino]", "Transferir entre centros de apoyo", "Recursos"},
    {"critical_resources", :recursos_criticos, "critical_resources", "Recursos críticos", "Recursos"},
    {"report_person", :reportar_persona, "report_person documento nombre zona estado [edad]", "Registrar persona afectada", "Personas"},
    {"find_person", :buscar_persona, "find_person documento | nombre=.. | zona=.. | estado=..", "Buscar personas (por documento muestra su historial)", "Personas"},
    {"person_status", :cambiar_estado_persona, "person_status documento estado", "Cambiar estado de una persona", "Personas"},
    {"send_family_message", :enviar_mensaje, "send_family_message documento|familia:nombre \"mensaje\"", "Enviar mensaje familiar", "Personas"},
    {"list_family_messages", :listar_mensajes, "list_family_messages documento|familia:nombre", "Ver mensajes de una persona o familia", "Personas"},
    {"message_status", :marcar_mensaje, "message_status id entregado|pendiente", "Marcar mensaje", "Personas"},
    {"report_pet", :reportar_mascota, "report_pet lost|found especie nombre color tamaño zona contacto [\"caracteristicas\"]", "Reportar mascota perdida o encontrada", "Mascotas"},
    {"list_pets", :listar_mascotas, "list_pets [especie=.. zona=.. estado=..]", "Consultar reportes de mascotas", "Mascotas"},
    {"match_pets", :buscar_coincidencias, "match_pets", "Buscar posibles coincidencias", "Mascotas"},
    {"confirm_match", :confirmar_coincidencia, "confirm_match id_perdida id_encontrada", "Confirmar coincidencia y cerrar ambos reportes", "Mascotas"},
    {"register_shelter", :registrar_albergue, "register_shelter codigo \"nombre\" zona capacidad [ocupacion]", "Registrar albergue", "Albergues"},
    {"check_shelter", :consultar_albergue, "check_shelter [codigo]", "Consultar un albergue (sin código: reporte por ocupación)", "Albergues"},
    {"register_entry", :registrar_ingreso, "register_entry albergue documento", "Registrar ingreso de una persona", "Albergues"},
    {"register_exit", :registrar_salida, "register_exit albergue documento", "Registrar salida de una persona", "Albergues"},
    {"summary", :resumen, "summary", "Resumen global", "Reportes"},
    {"simulate_assign", :demo_concurrencia, "simulate_assign recurso necesidad1 necesidad2 ...", "Asignar un recurso a varias necesidades AL MISMO TIEMPO", "Concurrencia"},
    {"help", nil, "help", "Mostrar esta ayuda", "General"},
    {"exit", nil, "exit", "Salir del sistema", "General"}
  ]

  # ---------------------------------------------------------------
  # Inicio y ciclo principal
  # ---------------------------------------------------------------

  def iniciar do
    usuarios = Usuarios.asegurar_administrador(Usuarios.cargar())
    Usuarios.guardar(usuarios)

    estado = %{
      usuarios: usuarios,
      conectados: MapSet.new(),
      actual: nil,
      zonas: Zonas.cargar(),
      necesidades: Necesidades.cargar(),
      personas: Personas.cargar(),
      mensajes: MensajesFamiliares.cargar(),
      mascotas: Mascotas.cargar()
    }

    IO.puts("\n=== SISTEMA DE COORDINACIÓN Y GESTIÓN DE EMERGENCIAS ===")
    IO.puts("Datos recuperados de los archivos de texto.")
    IO.puts("Escriba 'help' para ver los comandos.\n")
    ciclo(estado)
  end

  # Ciclo recursivo: lee un comando, lo ejecuta y se llama de nuevo con el estado actualizado.
  defp ciclo(estado) do
    case IO.gets(indicador(estado)) do
      :eof ->
        salir()

      {:error, _} ->
        salir()

      linea ->
        case separar_palabras(linea) do
          [] -> ciclo(estado)
          ["exit"] -> salir()
          palabras -> ciclo(ejecutar(estado, palabras))
        end
    end
  end

  defp indicador(%{actual: nil}), do: "> "
  defp indicador(%{actual: usuario}), do: "#{usuario.usuario}> "

  defp salir, do: IO.puts("Hasta pronto. La información quedó guardada en datos/.")

  # Separa una línea en palabras. Lo que está entre comillas es una sola palabra.
  # Ejemplo: ~s(register_need agua 30 critica centro "Punto sector 3")
  #   -> ["register_need", "agua", "30", "critica", "centro", "Punto sector 3"]
  def separar_palabras(linea) do
    Regex.scan(~r/"([^"]*)"|(\S+)/u, linea)
    |> Enum.map(fn
      [_completo, entre_comillas] -> entre_comillas
      [_completo, "", palabra] -> palabra
    end)
  end

  # ---------------------------------------------------------------
  # Despacho de comandos
  # ---------------------------------------------------------------

  # Comandos que no requieren estar conectado.
  defp ejecutar(estado, ["help" | _]), do: mostrar_ayuda(estado)
  defp ejecutar(estado, ["connect" | argumentos]), do: conectar(estado, argumentos)
  defp ejecutar(estado, ["disconnect" | _]), do: desconectar(estado)

  # El resto requiere un usuario conectado con permiso para la acción.
  defp ejecutar(estado, [nombre | argumentos]) do
    case List.keyfind(@comandos, nombre, 0) do
      nil ->
        IO.puts("Comando desconocido: #{nombre}. Escriba 'help' para ver los comandos.")
        estado

      {_nombre, accion, _uso, _descripcion, _grupo} ->
        con_permiso(estado, accion, fn usuario -> despachar(nombre, argumentos, estado, usuario) end)
    end
  end

  defp con_permiso(%{actual: nil} = estado, _accion, _funcion) do
    IO.puts("Debe conectarse primero: connect usuario contraseña")
    estado
  end

  defp con_permiso(estado, accion, funcion) do
    case Usuarios.autorizar(estado.actual, accion) do
      :ok ->
        funcion.(estado.actual)

      {:error, motivo} ->
        mostrar_error(motivo)
        estado
    end
  end

  # ----- Usuarios -----
  defp despachar("activity", argumentos, estado, _usuario) when length(argumentos) <= 1 do
    filtro = List.first(argumentos, "")

    case Usuarios.consultar_actividad(filtro) do
      [] -> IO.puts("Sin actividad registrada.")
      registros -> Enum.each(registros, fn a -> IO.puts("  #{a.fecha} | #{a.usuario} | #{a.accion}") end)
    end

    estado
  end

  # ----- Zonas -----
  defp despachar("register_zone", [codigo, nombre, nivel], estado, usuario) do
    despachar("register_zone", [codigo, nombre, nivel, "0"], estado, usuario)
  end

  defp despachar("register_zone", [codigo, nombre, nivel, personas], estado, usuario) do
    case Zonas.registrar_zona(estado.zonas, codigo, nombre, nivel, personas) do
      {:ok, zonas, zona} ->
        Zonas.guardar(zonas)
        exito(usuario, "register_zone #{zona.codigo}", "Zona #{zona.codigo} registrada.")
        %{estado | zonas: zonas}

      {:error, motivo} ->
        mostrar_error(motivo)
        estado
    end
  end

  defp despachar("register_sector", [zona, codigo, nombre, nivel], estado, usuario) do
    despachar("register_sector", [zona, codigo, nombre, nivel, "0"], estado, usuario)
  end

  defp despachar("register_sector", [zona, codigo, nombre, nivel, personas], estado, usuario) do
    case Zonas.registrar_sector(estado.zonas, zona, codigo, nombre, nivel, personas) do
      {:ok, zonas, sector} ->
        Zonas.guardar(zonas)
        exito(usuario, "register_sector #{zona} #{sector.codigo}", "Sector #{sector.codigo} registrado en #{zona}.")
        %{estado | zonas: zonas}

      {:error, motivo} ->
        mostrar_error(motivo)
        estado
    end
  end

  defp despachar("register_point", [zona, sector, codigo, nombre], estado, usuario) do
    case Zonas.registrar_punto(estado.zonas, zona, sector, codigo, nombre) do
      {:ok, zonas, punto} ->
        Zonas.guardar(zonas)
        exito(usuario, "register_point #{zona} #{sector} #{punto.codigo}", "Punto de atención #{punto.codigo} registrado.")
        %{estado | zonas: zonas}

      {:error, motivo} ->
        mostrar_error(motivo)
        estado
    end
  end

  defp despachar("zone_status", [codigo], estado, _usuario) do
    case Zonas.buscar_zona(estado.zonas, codigo) do
      {:ok, zona} ->
        info = Reportes.estado_zona(zona, datos_globales(estado))
        e = info.estadisticas
        IO.puts("Zona #{e.codigo} - #{e.nombre} (nivel #{e.nivel})")
        IO.puts("  Personas afectadas: zona #{e.personas_zona} + sectores #{e.personas_sectores} = #{e.personas_total}")
        IO.puts("  Sectores: #{e.total_sectores} | Puntos de atención: #{e.total_puntos}")
        IO.puts("  Puntos: " <> Enum.join(Enum.map(e.puntos, fn p -> "#{p.codigo} (#{p.nombre}, sector #{p.sector})" end), ", "))
        IO.puts("  Sectores críticos: " <> Enum.join(Enum.map(e.sectores_criticos, fn s -> s.codigo end), ", "))
        IO.puts("  Necesidades por estado: #{inspect(info.necesidades)}")
        IO.puts("  Recursos en la zona: #{length(info.recursos)} | Albergues: #{length(info.albergues)}")
        IO.puts("  Personas registradas: #{info.personas} | Reportes de mascotas: #{info.mascotas}")

      {:error, motivo} ->
        mostrar_error(motivo)
    end

    estado
  end

  # ----- Necesidades -----
  defp despachar("register_need", [tipo, cantidad, prioridad, zona, descripcion], estado, usuario) do
    despachar("register_need", [tipo, cantidad, prioridad, zona, descripcion, "zona", zona], estado, usuario)
  end

  defp despachar("register_need", [tipo, cantidad, prioridad, zona, descripcion, tipo_b, beneficiario], estado, usuario) do
    datos = %{
      tipo: tipo,
      cantidad: cantidad,
      prioridad: prioridad,
      zona: zona,
      descripcion: descripcion,
      responsable: usuario.usuario,
      tipo_beneficiario: tipo_b,
      beneficiario: beneficiario
    }

    case Necesidades.registrar_necesidad(estado.necesidades, estado.zonas, datos) do
      {:ok, necesidades, n} ->
        Necesidades.guardar(necesidades)
        exito(usuario, "register_need #{n.id}", "Necesidad #{n.id} registrada.")
        %{estado | necesidades: necesidades}

      {:error, motivo} ->
        mostrar_error(motivo)
        estado
    end
  end

  defp despachar("list_needs", filtros, estado, _usuario) do
    lista = Necesidades.filtrar(estado.necesidades, leer_filtros(filtros))
    mostrar_lista(lista, &mostrar_necesidad/1, "No hay necesidades.")
    estado
  end

  defp despachar("assign_resource", [id, referencia], estado, usuario) do
    asignar_recurso(estado, usuario, id, referencia, nil)
  end

  defp despachar("assign_resource", [id, referencia, cantidad], estado, usuario) do
    asignar_recurso(estado, usuario, id, referencia, cantidad)
  end

  defp despachar("need_status", [id, nuevo], estado, usuario) do
    case Necesidades.cambiar_estado(estado.necesidades, id, nuevo) do
      {:ok, necesidades, n} ->
        Necesidades.guardar(necesidades)
        exito(usuario, "need_status #{id} #{n.estado}", "Necesidad #{id} ahora está #{n.estado}.")
        %{estado | necesidades: necesidades}

      {:error, motivo} ->
        mostrar_error(motivo)
        estado
    end
  end

  defp despachar("pending_needs", [], estado, _usuario) do
    mostrar_lista(Reportes.necesidades_pendientes(estado.necesidades), &mostrar_necesidad/1, "No hay necesidades pendientes.")
    estado
  end

  # ----- Recursos -----
  # Si no se indica la zona se usa la zona principal del usuario; si no se indica el nombre, la categoría.
  defp despachar("register_resource", [codigo, categoria, cantidad, unidad, ubicacion], estado, usuario) do
    despachar("register_resource", [codigo, categoria, cantidad, unidad, ubicacion, usuario.zona, categoria], estado, usuario)
  end

  defp despachar("register_resource", [codigo, categoria, cantidad, unidad, ubicacion, zona], estado, usuario) do
    despachar("register_resource", [codigo, categoria, cantidad, unidad, ubicacion, zona, categoria], estado, usuario)
  end

  defp despachar("register_resource", [codigo, categoria, cantidad, unidad, ubicacion, zona, nombre], estado, usuario) do
    datos = %{codigo: codigo, categoria: categoria, nombre: nombre, cantidad: cantidad, unidad: unidad, ubicacion: ubicacion, zona: zona}

    with :ok <- Zonas.validar_zona(estado.zonas, zona),
         {:ok, r} <- ServidorInventario.registrar_recurso(datos, usuario.usuario) do
      exito(usuario, "register_resource #{r.codigo}", "Recurso #{r.codigo} registrado con #{r.cantidad} #{r.unidad} en #{r.ubicacion}.")
    else
      {:error, motivo} -> mostrar_error(motivo)
    end

    estado
  end

  defp despachar("list_resources", filtros, estado, _usuario) do
    f = leer_filtros(filtros)
    resultado = ServidorInventario.disponibilidad(Map.get(f, "categoria", ""), Map.get(f, "zona", ""))
    mostrar_lista(resultado.recursos, &mostrar_recurso/1, "No hay recursos.")
    if filtros != [], do: IO.puts("Total disponible: #{resultado.total}")
    estado
  end

  defp despachar("resource_in", [codigo, cantidad], estado, usuario) do
    case ServidorInventario.registrar_entrada(codigo, cantidad, usuario.usuario) do
      {:ok, r} -> exito(usuario, "resource_in #{codigo} #{cantidad}", "Nuevo saldo de #{codigo}: #{r.cantidad} #{r.unidad}.")
      {:error, motivo} -> mostrar_error(motivo)
    end

    estado
  end

  defp despachar("resource_out", [codigo, cantidad], estado, usuario) do
    case ServidorInventario.registrar_salida(codigo, cantidad, usuario.usuario) do
      {:ok, r} -> exito(usuario, "resource_out #{codigo} #{cantidad}", "Nuevo saldo de #{codigo}: #{r.cantidad} #{r.unidad}.")
      {:error, motivo} -> mostrar_error(motivo)
    end

    estado
  end

  defp despachar("transfer_resource", [codigo, origen, destino, cantidad], estado, usuario) do
    despachar("transfer_resource", [codigo, origen, destino, cantidad, ""], estado, usuario)
  end

  defp despachar("transfer_resource", [codigo, origen, destino, cantidad, zona_destino], estado, usuario) do
    case ServidorInventario.transferir(codigo, origen, destino, cantidad, zona_destino, usuario.usuario) do
      {:ok, codigo_destino} ->
        exito(usuario, "transfer_resource #{codigo} #{origen} #{destino} #{cantidad}",
          "Transferencia realizada. Recurso en destino: #{codigo_destino}.")

      {:error, motivo} ->
        mostrar_error(motivo)
    end

    estado
  end

  defp despachar("critical_resources", [], estado, _usuario) do
    criticos = Reportes.recursos_criticos(ServidorInventario.listar_recursos(), estado.necesidades)
    IO.puts("Categorías críticas (disponible < demanda abierta, o disponible <= #{Reportes.umbral_recurso_critico()}):")

    mostrar_lista(
      criticos,
      fn c -> IO.puts("  #{c.categoria} | disponible #{c.disponible} | demanda #{c.demanda} | déficit #{c.deficit}") end,
      "No hay recursos críticos."
    )

    estado
  end

  # ----- Personas y mensajes -----
  # La edad es obligatoria; si no se escribe en el comando, se pregunta.
  defp despachar("report_person", [documento, nombre, zona, estado_p], estado, usuario) do
    despachar("report_person", [documento, nombre, zona, estado_p, leer("Edad: ")], estado, usuario)
  end

  defp despachar("report_person", [documento, nombre, zona, estado_p, edad], estado, usuario) do
    datos = %{documento: documento, nombre: nombre, edad: edad, zona: zona, estado: estado_p, usuario: usuario.usuario}

    case Personas.registrar_persona(estado.personas, estado.zonas, datos) do
      {:ok, personas, p} ->
        Personas.guardar(personas)
        exito(usuario, "report_person #{p.documento}", "Persona #{p.id} (#{p.nombre}) registrada como #{p.estado}.")
        %{estado | personas: personas}

      {:error, motivo} ->
        mostrar_error(motivo)
        estado
    end
  end

  # find_person nombre=andres | zona=centro | estado=localizada  -> lista de personas
  defp despachar("find_person", ["nombre=" <> valor], estado, _u), do: buscar_personas(estado, :nombre, valor)
  defp despachar("find_person", ["zona=" <> valor], estado, _u), do: buscar_personas(estado, :zona, valor)
  defp despachar("find_person", ["estado=" <> valor], estado, _u), do: buscar_personas(estado, :estado, valor)

  # find_person documento -> datos de la persona y su historial de estados
  defp despachar("find_person", [documento], estado, _usuario) do
    case Personas.buscar_por_documento(estado.personas, documento) do
      {:ok, p} ->
        mostrar_persona(p)
        IO.puts("  Historial de estados:")
        Enum.each(p.historial, fn h -> IO.puts("    #{h.fecha} | #{h.anterior} -> #{h.nuevo} | por #{h.usuario}") end)

      {:error, motivo} ->
        mostrar_error(motivo)
    end

    estado
  end

  defp despachar("person_status", [documento, nuevo], estado, usuario) do
    case Personas.cambiar_estado(estado.personas, documento, nuevo, usuario.usuario) do
      {:ok, personas, p} ->
        Personas.guardar(personas)
        exito(usuario, "person_status #{documento} #{p.estado}", "#{p.nombre} ahora está #{p.estado}.")
        %{estado | personas: personas}

      {:error, motivo} ->
        mostrar_error(motivo)
        estado
    end
  end

  # Destinatario: el documento de una persona registrada, o "familia:nombre" para una familia.
  defp despachar("send_family_message", [destinatario, contenido], estado, usuario) do
    {tipo, a_quien} = tipo_destinatario(destinatario)

    case MensajesFamiliares.registrar_mensaje(estado.mensajes, estado.personas, usuario.usuario, tipo, a_quien, contenido) do
      {:ok, mensajes, m} ->
        MensajesFamiliares.guardar(mensajes)
        exito(usuario, "send_family_message #{m.id} #{a_quien}", "Mensaje #{m.id} registrado para #{a_quien}.")
        %{estado | mensajes: mensajes}

      {:error, motivo} ->
        mostrar_error(motivo)
        estado
    end
  end

  defp despachar("list_family_messages", [destinatario], estado, _usuario) do
    {_tipo, a_quien} = tipo_destinatario(destinatario)

    mostrar_lista(
      MensajesFamiliares.listar_mensajes(estado.mensajes, a_quien),
      fn m -> IO.puts("  #{m.id} | #{m.fecha} | de #{m.remitente} | #{m.estado} | \"#{m.contenido}\"") end,
      "No hay mensajes."
    )

    estado
  end

  defp despachar("message_status", [id, nuevo], estado, usuario) do
    case MensajesFamiliares.marcar_estado(estado.mensajes, id, nuevo) do
      {:ok, mensajes, m} ->
        MensajesFamiliares.guardar(mensajes)
        exito(usuario, "message_status #{id} #{m.estado}", "Mensaje #{id} marcado como #{m.estado}.")
        %{estado | mensajes: mensajes}

      {:error, motivo} ->
        mostrar_error(motivo)
        estado
    end
  end

  # ----- Mascotas -----
  defp despachar("report_pet", [tipo, especie, nombre, color, tamano, zona, contacto], estado, usuario) do
    despachar("report_pet", [tipo, especie, nombre, color, tamano, zona, contacto, ""], estado, usuario)
  end

  defp despachar("report_pet", [tipo, especie, nombre, color, tamano, zona, contacto, caracteristicas], estado, usuario) do
    datos = %{
      tipo: tipo,
      especie: especie,
      nombre: nombre,
      caracteristicas: caracteristicas,
      color: color,
      tamano: tamano,
      zona: zona,
      contacto: contacto,
      reportado_por: usuario.usuario
    }

    case Mascotas.registrar_reporte(estado.mascotas, estado.zonas, datos) do
      {:ok, mascotas, m} ->
        Mascotas.guardar(mascotas)
        exito(usuario, "report_pet #{m.id} #{m.tipo}", "Reporte #{m.id} (#{m.tipo}) registrado.")
        %{estado | mascotas: mascotas}

      {:error, motivo} ->
        mostrar_error(motivo)
        estado
    end
  end

  defp despachar("list_pets", filtros, estado, _usuario) do
    mostrar_lista(Mascotas.consultar(estado.mascotas, leer_filtros(filtros)), &mostrar_mascota/1, "No hay reportes.")
    estado
  end

  defp despachar("match_pets", [], estado, usuario) do
    {mascotas, coincidencias} = Mascotas.marcar_posibles_coincidencias(estado.mascotas)
    Mascotas.guardar(mascotas)
    IO.puts("Posibles coincidencias (puntaje >= #{Mascotas.umbral()} de 100):")

    mostrar_lista(
      coincidencias,
      fn c -> IO.puts("  Perdida #{c.perdida} <-> Encontrada #{c.encontrada} | puntaje #{c.puntaje}") end,
      "No se encontraron coincidencias."
    )

    Usuarios.registrar_actividad(usuario.usuario, "match_pets (#{length(coincidencias)} coincidencias)")
    %{estado | mascotas: mascotas}
  end

  defp despachar("confirm_match", [perdida, encontrada], estado, usuario) do
    case Mascotas.confirmar_coincidencia(estado.mascotas, perdida, encontrada) do
      {:ok, mascotas} ->
        Mascotas.guardar(mascotas)
        exito(usuario, "confirm_match #{perdida} #{encontrada}", "Coincidencia confirmada. Ambos reportes quedaron resueltos.")
        %{estado | mascotas: mascotas}

      {:error, motivo} ->
        mostrar_error(motivo)
        estado
    end
  end

  # ----- Albergues -----
  defp despachar("register_shelter", [codigo, nombre, zona, capacidad], estado, usuario) do
    despachar("register_shelter", [codigo, nombre, zona, capacidad, "0"], estado, usuario)
  end

  defp despachar("register_shelter", [codigo, nombre, zona, capacidad, ocupacion], estado, usuario) do
    datos = %{codigo: codigo, nombre: nombre, zona: zona, capacidad: capacidad, ocupacion: ocupacion}

    with :ok <- Zonas.validar_zona(estado.zonas, zona),
         {:ok, a} <- ServidorAlbergues.registrar_albergue(datos) do
      exito(usuario, "register_shelter #{a.codigo}", "Albergue #{a.codigo} registrado (capacidad #{a.capacidad}).")
    else
      {:error, motivo} -> mostrar_error(motivo)
    end

    estado
  end

  # Sin código: reporte de albergues ordenados por nivel de ocupación.
  defp despachar("check_shelter", [], estado, _usuario) do
    IO.puts("Albergues ordenados por ocupación:")

    mostrar_lista(
      ServidorAlbergues.reporte_ocupacion(),
      fn a -> IO.puts("  #{a.codigo} | #{a.nombre} | #{a.ocupacion}/#{a.capacidad} | #{a.porcentaje}% | cupos #{a.cupos}") end,
      "No hay albergues registrados."
    )

    estado
  end

  defp despachar("check_shelter", [codigo], estado, _usuario) do
    case ServidorAlbergues.consultar(codigo) do
      {:ok, albergue} ->
        d = Reportes.detalle_albergue(albergue, ServidorInventario.listar_recursos(), estado.necesidades)
        IO.puts("#{albergue.codigo} - #{albergue.nombre} (zona #{albergue.zona})")
        IO.puts("  Ocupación: #{albergue.ocupacion}/#{albergue.capacidad} (#{d.porcentaje}%) | Cupos disponibles: #{d.cupos}")
        IO.puts("  Personas registradas: " <> Enum.join(MapSet.to_list(albergue.personas), ", "))
        IO.puts("  Recursos en el albergue:")
        mostrar_lista(d.recursos, &mostrar_recurso/1, "    (ninguno)")
        IO.puts("  Necesidades asociadas:")
        mostrar_lista(d.necesidades, &mostrar_necesidad/1, "    (ninguna)")

      {:error, motivo} ->
        mostrar_error(motivo)
    end

    estado
  end

  defp despachar("register_entry", [codigo, documento], estado, usuario) do
    case ServidorAlbergues.registrar_ingreso(codigo, documento) do
      {:ok, a} ->
        # Si la persona está registrada, su estado pasa a "en_albergue".
        personas = Personas.actualizar_por_ingreso_albergue(estado.personas, documento, usuario.usuario)
        Personas.guardar(personas)
        exito(usuario, "register_entry #{codigo} #{documento}", "Ingreso registrado. Ocupación #{a.ocupacion}/#{a.capacidad}.")
        %{estado | personas: personas}

      {:error, motivo} ->
        mostrar_error(motivo)
        estado
    end
  end

  defp despachar("register_exit", [codigo, documento], estado, usuario) do
    case ServidorAlbergues.registrar_salida(codigo, documento) do
      {:ok, a} -> exito(usuario, "register_exit #{codigo} #{documento}", "Salida registrada. Ocupación #{a.ocupacion}/#{a.capacidad}.")
      {:error, motivo} -> mostrar_error(motivo)
    end

    estado
  end

  # ----- Reportes -----
  defp despachar("summary", [], estado, _usuario) do
    r = Reportes.resumen(datos_globales(estado))
    IO.puts("=== RESUMEN GLOBAL ===")
    IO.puts("Zonas registradas: #{r.zonas}")
    IO.puts("Necesidades: #{r.necesidades.total} (abiertas #{r.necesidades.pendientes}) #{inspect(r.necesidades.por_estado)}")
    IO.puts("Recursos restantes por categoría: #{inspect(r.recursos.por_categoria)}")
    IO.puts("Personas: #{r.personas.total} (con ubicación conocida #{r.personas.localizadas}) #{inspect(r.personas.por_estado)}")
    IO.puts("Mensajes familiares: #{r.mensajes.total} #{inspect(r.mensajes.por_estado)}")
    IO.puts("Mascotas: #{r.mascotas.total} #{inspect(r.mascotas.por_tipo)} #{inspect(r.mascotas.por_estado)}")
    IO.puts("Albergues: #{r.albergues.total} | ocupación #{r.albergues.ocupacion_total}/#{r.albergues.capacidad_total}")
    estado
  end

  # ----- Concurrencia -----
  defp despachar("simulate_assign", [referencia | ids], estado, usuario) when ids != [] do
    IO.puts("Lanzando un proceso por necesidad (todos piden #{referencia} al mismo tiempo)...")
    {necesidades, resultados} = SimuladorUsuarios.asignar_en_paralelo(estado.necesidades, referencia, ids, usuario.usuario)
    Necesidades.guardar(necesidades)

    Enum.each(resultados, fn
      {id, {:ok, a}} -> IO.puts("  #{id}: CONFIRMADA (#{a.cantidad} unidades de #{a.recurso}, quedan #{a.restante})")
      {id, {:error, motivo}} -> IO.puts("  #{id}: RECHAZADA (#{texto_error(motivo)})")
    end)

    Usuarios.registrar_actividad(usuario.usuario, "simulate_assign #{referencia} #{Enum.join(ids, " ")}")
    %{estado | necesidades: necesidades}
  end

  # Si ninguna cláusula coincide, los argumentos no son correctos: se muestra la forma de uso.
  defp despachar(nombre, _argumentos, estado, _usuario) do
    mostrar_uso(nombre)
    estado
  end

  # ---------------------------------------------------------------
  # Conexión (connect / disconnect)
  # ---------------------------------------------------------------

  defp conectar(estado, [usuario, contrasena | datos]) do
    case datos_de_registro(estado, usuario, datos) do
      {:ok, datos_registro} ->
        case Usuarios.conectar(estado.usuarios, estado.conectados, usuario, contrasena, datos_registro) do
          {:ok, usuarios, conectados, u, modo} ->
            if modo == :registrado do
              Usuarios.guardar(usuarios)
              IO.puts("Usuario #{u.usuario} registrado automáticamente.")
            end

            Usuarios.registrar_actividad(u.usuario, "connect (#{modo})")
            IO.puts("Conectado como #{u.usuario} (#{u.rol}, zona #{u.zona}).")
            %{estado | usuarios: usuarios, conectados: conectados, actual: u}

          {:error, motivo} ->
            mostrar_error(motivo)
            estado
        end

      :faltan_datos ->
        IO.puts("El usuario #{usuario} no existe. Para registrarlo indique tipo y zona:")
        mostrar_uso("connect")
        estado
    end
  end

  defp conectar(estado, _argumentos) do
    mostrar_uso("connect")
    estado
  end

  # Datos para el registro automático. Si el usuario ya existe no se necesitan.
  # El nombre completo es obligatorio: si no se escribió en el comando, se pregunta.
  defp datos_de_registro(estado, usuario, datos) do
    cond do
      Usuarios.existe?(estado.usuarios, usuario) -> {:ok, nil}
      match?([_tipo, _zona], datos) -> {:ok, %{rol: Enum.at(datos, 0), zona: Enum.at(datos, 1), nombre: leer("Nombre completo: ")}}
      match?([_tipo, _zona, _nombre], datos) -> {:ok, %{rol: Enum.at(datos, 0), zona: Enum.at(datos, 1), nombre: Enum.at(datos, 2)}}
      true -> :faltan_datos
    end
  end

  defp desconectar(%{actual: nil} = estado) do
    IO.puts("No hay un usuario conectado.")
    estado
  end

  defp desconectar(estado) do
    case Usuarios.desconectar(estado.conectados, estado.actual.usuario) do
      {:ok, conectados} ->
        Usuarios.registrar_actividad(estado.actual.usuario, "disconnect")
        IO.puts("Usuario #{estado.actual.usuario} desconectado.")
        %{estado | conectados: conectados, actual: nil}

      {:error, motivo} ->
        mostrar_error(motivo)
        estado
    end
  end

  # ---------------------------------------------------------------
  # Funciones de apoyo
  # ---------------------------------------------------------------

  defp asignar_recurso(estado, usuario, id, referencia, cantidad) do
    case Necesidades.asignar_recurso(estado.necesidades, id, referencia, cantidad, usuario.usuario) do
      {:ok, necesidades, a} ->
        Necesidades.guardar(necesidades)
        mensaje = "Asignadas #{a.cantidad} unidades de #{a.recurso} a #{id}. Quedan #{a.restante}."
        exito(usuario, "assign_resource #{id} #{a.recurso} #{a.cantidad}", mensaje)
        %{estado | necesidades: necesidades}

      {:error, motivo} ->
        mostrar_error(motivo)
        estado
    end
  end

  defp buscar_personas(estado, criterio, valor) do
    mostrar_lista(Personas.buscar(estado.personas, criterio, valor), &mostrar_persona/1, "No se encontraron personas.")
    estado
  end

  # "familia:gomez" -> {:familia, "gomez"};  "1094" -> {:persona, "1094"}
  defp tipo_destinatario("familia:" <> familia), do: {:familia, familia}
  defp tipo_destinatario(documento), do: {:persona, documento}

  defp exito(usuario, actividad, mensaje) do
    Usuarios.registrar_actividad(usuario.usuario, actividad)
    IO.puts(mensaje)
  end

  defp datos_globales(estado) do
    %{
      zonas: estado.zonas,
      necesidades: estado.necesidades,
      personas: estado.personas,
      mensajes: estado.mensajes,
      mascotas: estado.mascotas,
      recursos: ServidorInventario.listar_recursos(),
      albergues: ServidorAlbergues.listar_albergues()
    }
  end

  defp leer(mensaje) do
    case IO.gets(mensaje) do
      :eof -> ""
      {:error, _} -> ""
      texto -> String.trim(texto)
    end
  end

  # Convierte ["zona=centro", "prioridad=critica"] en %{"zona" => "centro", "prioridad" => "critica"}.
  defp leer_filtros(palabras) do
    Enum.reduce(palabras, %{}, fn par, filtros ->
      case String.split(par, "=", parts: 2) do
        [clave, valor] when valor != "" -> Map.put(filtros, String.downcase(clave), valor)
        _ -> filtros
      end
    end)
  end

  defp mostrar_ayuda(estado) do
    IO.puts("Comandos disponibles (los textos con espacios van entre comillas):")

    @comandos
    |> Enum.map(fn {_n, _a, _u, _d, grupo} -> grupo end)
    |> Enum.uniq()
    |> Enum.each(fn grupo ->
      visibles = for {_n, accion, uso, desc, ^grupo} <- @comandos, puede_usar?(estado, accion), do: {uso, desc}

      # Solo se muestran los grupos que tienen algún comando permitido para el rol.
      if visibles != [] do
        IO.puts("\n  [#{grupo}]")

        Enum.each(visibles, fn {uso, descripcion} ->
          if String.length(uso) <= 62 do
            IO.puts("    #{String.pad_trailing(uso, 62)} #{descripcion}")
          else
            IO.puts("    #{uso}")
            IO.puts("    #{String.duplicate(" ", 62)} #{descripcion}")
          end
        end)
      end
    end)

    IO.puts("")
    estado
  end

  # La ayuda solo muestra los comandos que el rol del usuario puede usar.
  defp puede_usar?(_estado, nil), do: true
  defp puede_usar?(%{actual: nil}, _accion), do: true
  defp puede_usar?(%{actual: usuario}, accion), do: Usuarios.tiene_permiso?(usuario, accion)

  defp mostrar_uso(nombre) do
    case List.keyfind(@comandos, nombre, 0) do
      {_nombre, _accion, uso, _descripcion, _grupo} -> IO.puts("Uso: " <> uso)
      nil -> IO.puts("Comando desconocido: #{nombre}")
    end
  end

  defp mostrar_lista([], _mostrar, mensaje_vacio), do: IO.puts(mensaje_vacio)
  defp mostrar_lista(lista, mostrar, _mensaje_vacio), do: Enum.each(lista, mostrar)

  defp texto_necesidad(n) do
    "#{n.id} | #{n.tipo} | #{n.asignada}/#{n.cantidad} | #{n.prioridad} | #{n.zona} | #{n.estado} | " <>
      "#{n.tipo_beneficiario}: #{n.beneficiario} | #{n.descripcion}"
  end

  defp mostrar_necesidad(n), do: IO.puts("  " <> texto_necesidad(n))

  defp mostrar_recurso(r) do
    IO.puts("  #{r.codigo} | #{r.nombre} | #{r.categoria} | #{r.cantidad} #{r.unidad} | #{r.ubicacion} | zona #{r.zona}")
  end

  defp mostrar_persona(p) do
    IO.puts("  #{p.id} | doc #{p.documento} | #{p.nombre} | #{p.edad} años | zona #{p.zona} | #{p.estado}")
  end

  defp mostrar_mascota(m) do
    IO.puts(
      "  #{m.id} | #{m.tipo} | #{m.especie} | #{m.nombre} | #{m.color} | #{m.tamano} | #{m.zona} | " <>
        "#{m.estado} | contacto #{m.contacto} | #{m.caracteristicas}" <>
        if(m.coincidencia != "", do: " | coincide con #{m.coincidencia}", else: "")
    )
  end

  defp mostrar_error(motivo) do
    IO.puts("Error: " <> texto_error(motivo))
  end

  # Traduce los motivos de error a mensajes para el usuario.
  defp texto_error(motivo) do
    mensajes = %{
      sin_permiso: "su rol no tiene permiso para este comando",
      usuario_no_existe: "el usuario no existe",
      contrasena_incorrecta: "contraseña incorrecta",
      usuario_repetido: "el usuario ya existe",
      usuario_vacio: "el usuario no puede estar vacío",
      usuario_con_espacios: "el usuario no puede tener espacios",
      contrasena_vacia: "la contraseña no puede estar vacía",
      nombre_vacio: "el nombre no puede estar vacío",
      rol_invalido: "tipo de usuario no válido (ciudadano/voluntario/coordinador)",
      rol_no_permitido: "no es posible auto-registrarse como administrador",
      usuario_no_conectado: "el usuario no está conectado",
      codigo_repetido: "el código ya existe",
      codigo_vacio: "el código no puede estar vacío",
      nivel_invalido: "nivel no válido (critico/alto/medio/bajo)",
      zona_no_existe: "la zona no existe (regístrela con register_zone)",
      zona_vacia: "la zona no puede estar vacía",
      sector_no_existe: "el sector no existe",
      punto_no_existe: "el punto de atención no existe",
      numero_invalido: "debe escribir un número entero",
      cantidad_negativa: "la cantidad no puede ser negativa",
      cantidad_cero: "la cantidad debe ser mayor que cero",
      tipo_invalido: "tipo no válido (agua/alimentos/medicamentos/primeros_auxilios/refugio/transporte/rescate/otra)",
      prioridad_invalida: "prioridad no válida (critica/alta/media/baja)",
      descripcion_vacia: "la descripción no puede estar vacía",
      beneficiario_invalido: "asociación no válida (persona/familia/albergue/zona)",
      beneficiario_vacio: "debe indicar a quién se asocia la necesidad",
      necesidad_no_existe: "la necesidad no existe",
      necesidad_ya_atendida: "la necesidad ya fue atendida y no puede consumir más recursos",
      necesidad_cancelada: "la necesidad está cancelada",
      necesidad_ya_cerrada: "la necesidad ya está cerrada",
      estado_no_permite_asignar: "en ese estado la necesidad no puede recibir recursos",
      cantidad_excede_necesidad: "la cantidad supera lo que le falta a la necesidad",
      sin_necesidades_pendientes: "no hay necesidades pendientes",
      estado_invalido: "estado no válido",
      transicion_invalida: "ese cambio de estado no está permitido",
      recurso_no_existe: "no existe un recurso con ese código o categoría",
      inventario_insuficiente: "inventario insuficiente",
      categoria_vacia: "la categoría no puede estar vacía",
      unidad_vacia: "la unidad no puede estar vacía",
      ubicacion_vacia: "la ubicación no puede estar vacía",
      origen_incorrecto: "el recurso no está en el centro de origen indicado",
      destino_vacio: "el destino no puede estar vacío",
      mismo_origen_destino: "el origen y el destino son iguales",
      documento_vacio: "el documento no puede estar vacío",
      documento_repetido: "ya existe una persona con ese documento",
      edad_invalida: "edad no válida",
      persona_no_existe: "no hay una persona registrada con ese documento",
      persona_ya_reunificada: "la persona ya fue reunificada (caso cerrado)",
      tipo_destinatario_invalido: "destinatario no válido",
      destinatario_vacio: "el destinatario no puede estar vacío",
      contenido_vacio: "el mensaje no puede estar vacío",
      mensaje_no_existe: "el mensaje no existe",
      mensaje_ya_tiene_ese_estado: "el mensaje ya tiene ese estado",
      tipo_reporte_invalido: "tipo de reporte no válido (lost/found o perdida/encontrada)",
      especie_vacia: "la especie no puede estar vacía",
      color_vacio: "el color no puede estar vacío",
      tamano_vacio: "el tamaño no puede estar vacío",
      contacto_vacio: "el contacto no puede estar vacío",
      reporte_no_existe: "el reporte no existe",
      reporte_ya_resuelto: "el reporte ya fue resuelto",
      tipos_no_corresponden: "indique primero el reporte perdido y luego el encontrado",
      albergue_no_existe: "el albergue no existe",
      capacidad_superada: "se supera la capacidad máxima del albergue",
      persona_ya_en_albergue: "la persona ya está registrada en el albergue",
      persona_no_esta_en_albergue: "la persona no está registrada en ese albergue",
      proceso_no_existe: "proceso no válido (inventario/albergues/actividad)",
      no_reiniciado: "el proceso no se reinició a tiempo"
    }

    Map.get(mensajes, motivo, inspect(motivo))
  end
end
