# Pruebas del sistema con ExUnit (incluido en Elixir, no requiere dependencias).
# Ejecutar desde la carpeta proyecto_emergencias con:   elixir pruebas/pruebas.exs
#
# Cada prueba usa una carpeta temporal de datos (variable EMERGENCIAS_DATOS),
# así las pruebas nunca modifican los archivos reales de datos/.

ExUnit.start()

raiz = Path.expand("..", __DIR__)

# Mismo orden de carga que main.exs (sin iniciar la interfaz).
for archivo <- [
      "modulos/utilidades.exs",
      "modulos/persistencia.exs",
      "modulos/zonas.exs",
      "modulos/recursos.exs",
      "modulos/albergues.exs",
      "procesos/proceso_actividad.exs",
      "procesos/servidor_inventario.exs",
      "procesos/servidor_albergues.exs",
      "modulos/usuarios.exs",
      "modulos/necesidades.exs",
      "modulos/personas.exs",
      "modulos/mensajes_familiares.exs",
      "modulos/mascotas.exs",
      "modulos/reportes.exs",
      "procesos/simulador_usuarios.exs",
      "procesos/supervisor_emergencia.exs",
      "modulos/interfaz.exs"
    ] do
  Code.require_file(archivo, raiz)
end

defmodule Ayudas do
  # Crea una carpeta de datos vacía para la prueba e inicia el supervisor.
  def preparar_carpeta do
    carpeta = Path.join(System.tmp_dir!(), "emergencias_prueba_#{System.unique_integer([:positive])}")
    File.rm_rf!(carpeta)
    File.mkdir_p!(carpeta)
    System.put_env("EMERGENCIAS_DATOS", carpeta)
    carpeta
  end

  def zonas_de_prueba do
    {:ok, zonas, _} = Zonas.registrar_zona([], "centro", "Centro", "critico", 100)
    {:ok, zonas, _} = Zonas.registrar_zona(zonas, "zona_norte", "Zona Norte", "alto", 50)
    zonas
  end

  def datos_necesidad(tipo, cantidad, prioridad) do
    %{
      tipo: tipo,
      cantidad: cantidad,
      prioridad: prioridad,
      zona: "centro",
      descripcion: "prueba",
      responsable: "laura",
      tipo_beneficiario: "zona",
      beneficiario: "centro"
    }
  end

  def datos_recurso(codigo, categoria, cantidad, ubicacion \\ "centro_acopio_1") do
    %{codigo: codigo, nombre: "Recurso " <> categoria, categoria: categoria, cantidad: cantidad,
      unidad: "unidades", ubicacion: ubicacion, zona: "centro"}
  end
end

defmodule PruebasEmergencias do
  use ExUnit.Case

  setup do
    carpeta = Ayudas.preparar_carpeta()
    start_supervised!(SupervisorEmergencia)
    on_exit(fn -> File.rm_rf(carpeta) end)
    %{carpeta: carpeta}
  end

  # ---------------------------------------------------------------
  # Usuarios y permisos
  # ---------------------------------------------------------------

  test "connect registra automáticamente un usuario nuevo y luego valida su contraseña" do
    datos = %{nombre: "Laura Gómez", rol: "coordinador", zona: "centro"}

    {:ok, usuarios, conectados, laura, :registrado} =
      Usuarios.conectar(%{}, MapSet.new(), "laura", "1234", datos)

    assert laura.rol == :coordinador
    assert MapSet.member?(conectados, "laura")

    # Segunda conexión: ya existe, se valida la contraseña.
    assert {:ok, _, _, _, :autenticado} = Usuarios.conectar(usuarios, MapSet.new(), "laura", "1234", nil)
    assert {:error, :contrasena_incorrecta} = Usuarios.conectar(usuarios, MapSet.new(), "laura", "mala", nil)
  end

  test "no se puede auto-registrar un administrador ni repetir usuarios" do
    datos = %{nombre: "X", rol: "administrador", zona: "centro"}
    assert {:error, :rol_no_permitido} = Usuarios.conectar(%{}, MapSet.new(), "x", "1", datos)

    {:ok, usuarios, _} = Usuarios.registrar_usuario(%{}, "ana", "1", "Ana", :ciudadano, "centro")
    assert {:error, :usuario_repetido} = Usuarios.registrar_usuario(usuarios, "ana", "2", "Ana", :ciudadano, "centro")
  end

  test "los usuarios conectados se guardan en un MapSet sin repetidos" do
    datos = %{nombre: "Ana", rol: "ciudadano", zona: "centro"}
    {:ok, usuarios, conectados, _, _} = Usuarios.conectar(%{}, MapSet.new(), "ana", "1", datos)
    {:ok, _, conectados, _, _} = Usuarios.conectar(usuarios, conectados, "ana", "1", nil)
    assert MapSet.size(conectados) == 1

    assert {:ok, vacio} = Usuarios.desconectar(conectados, "ana")
    assert MapSet.size(vacio) == 0
    assert {:error, :usuario_no_conectado} = Usuarios.desconectar(vacio, "ana")
  end

  test "los permisos dependen del rol" do
    ciudadano = %{rol: :ciudadano}
    voluntario = %{rol: :voluntario}
    coordinador = %{rol: :coordinador}
    admin = %{rol: :administrador}

    assert :ok = Usuarios.autorizar(ciudadano, :registrar_necesidad)
    assert {:error, :sin_permiso} = Usuarios.autorizar(ciudadano, :registrar_zona)
    assert {:error, :sin_permiso} = Usuarios.autorizar(voluntario, :asignar_recurso)
    assert :ok = Usuarios.autorizar(coordinador, :asignar_recurso)
    assert {:error, :sin_permiso} = Usuarios.autorizar(coordinador, :ver_actividad)
    assert :ok = Usuarios.autorizar(admin, :ver_actividad)
  end

  test "la contraseña se guarda cifrada y se crea un administrador por defecto" do
    usuarios = Usuarios.asegurar_administrador(%{})
    assert usuarios["admin"].rol == :administrador
    refute usuarios["admin"].contrasena == "admin123"
    assert {:ok, _} = Usuarios.autenticar(usuarios, "admin", "admin123")
  end

  test "la actividad la registra el proceso independiente ProcesoActividad" do
    Usuarios.registrar_actividad("laura", "register_need N001")
    Usuarios.registrar_actividad("ana", "report_person 123")
    actividad = Usuarios.consultar_actividad("laura")
    assert [%{usuario: "laura", accion: "register_need N001"}] = actividad
  end

  # ---------------------------------------------------------------
  # Zonas y funciones recursivas
  # ---------------------------------------------------------------

  test "funciones recursivas sobre zona -> sectores -> puntos de atención" do
    zonas = Ayudas.zonas_de_prueba()
    {:ok, zonas, _} = Zonas.registrar_sector(zonas, "centro", "S1", "Sector 1", "critico", 40)
    {:ok, zonas, _} = Zonas.registrar_sector(zonas, "centro", "S2", "Sector 2", "medio", 25)
    {:ok, zonas, _} = Zonas.registrar_punto(zonas, "centro", "S1", "P1", "Hospital de campaña")
    {:ok, zonas, _} = Zonas.registrar_punto(zonas, "centro", "S1", "P2", "Puesto de agua")
    {:ok, zonas, _} = Zonas.registrar_punto(zonas, "centro", "S2", "P3", "Cocina comunitaria")

    {:ok, centro} = Zonas.buscar_zona(zonas, "centro")

    assert Zonas.sumar_personas_sectores(centro.sectores) == 65
    assert Zonas.contar_puntos(centro.sectores) == 3
    assert Enum.map(Zonas.obtener_puntos(centro.sectores), fn p -> p.codigo end) == ["P1", "P2", "P3"]
    assert {:ok, %{nombre: "Sector 2"}} = Zonas.buscar_sector(centro.sectores, "S2")
    assert {:error, :sector_no_existe} = Zonas.buscar_sector(centro.sectores, "S9")
    assert {:ok, %{nombre: "Cocina comunitaria", sector: "S2"}} = Zonas.buscar_punto(centro.sectores, "P3")
    assert [%{codigo: "S1"}] = Zonas.sectores_por_nivel(centro.sectores, :critico)

    stats = Zonas.estadisticas_zona(centro)
    assert stats.personas_total == 165
    assert stats.total_puntos == 3
  end

  test "las zonas validan códigos repetidos y niveles" do
    zonas = Ayudas.zonas_de_prueba()
    assert {:error, :codigo_repetido} = Zonas.registrar_zona(zonas, "centro", "Otra", "bajo", 1)
    assert {:error, :nivel_invalido} = Zonas.registrar_zona(zonas, "sur", "Sur", "terrible", 1)
    assert {:error, :cantidad_negativa} = Zonas.registrar_zona(zonas, "sur", "Sur", "bajo", -5)
    {:ok, zonas, _} = Zonas.registrar_sector(zonas, "centro", "S1", "Sector 1", "alto", 1)
    {:ok, zonas, _} = Zonas.registrar_punto(zonas, "centro", "S1", "P1", "Punto")
    assert {:error, :codigo_repetido} = Zonas.registrar_punto(zonas, "centro", "S1", "P1", "Otro")
  end

  # ---------------------------------------------------------------
  # Necesidades
  # ---------------------------------------------------------------

  test "registrar necesidades genera identificadores únicos y valida datos" do
    zonas = Ayudas.zonas_de_prueba()
    {:ok, lista, n1} = Necesidades.registrar_necesidad([], zonas, Ayudas.datos_necesidad("agua", "30", "critica"))
    {:ok, lista, n2} = Necesidades.registrar_necesidad(lista, zonas, Ayudas.datos_necesidad("alimentos", 10, "baja"))

    assert n1.id == "N001"
    assert n2.id == "N002"
    assert n1.estado == :pendiente

    assert {:error, :prioridad_invalida} = Necesidades.registrar_necesidad(lista, zonas, Ayudas.datos_necesidad("agua", 5, "urgente"))
    assert {:error, :cantidad_negativa} = Necesidades.registrar_necesidad(lista, zonas, Ayudas.datos_necesidad("agua", -5, "alta"))

    datos_zona_mala = %{Ayudas.datos_necesidad("agua", 5, "alta") | zona: "marte"}
    assert {:error, :zona_no_existe} = Necesidades.registrar_necesidad(lista, zonas, datos_zona_mala)
  end

  test "la prioridad ordena las necesidades y se pueden filtrar" do
    zonas = Ayudas.zonas_de_prueba()
    {:ok, lista, _} = Necesidades.registrar_necesidad([], zonas, Ayudas.datos_necesidad("agua", 5, "baja"))
    {:ok, lista, _} = Necesidades.registrar_necesidad(lista, zonas, Ayudas.datos_necesidad("rescate", 1, "critica"))
    {:ok, lista, _} = Necesidades.registrar_necesidad(lista, zonas, Ayudas.datos_necesidad("agua", 9, "alta"))

    ordenadas = Necesidades.ordenar_por_prioridad(lista)
    assert Enum.map(ordenadas, fn n -> n.prioridad end) == [:critica, :alta, :baja]
    assert {:ok, %{id: "N002"}} = Necesidades.siguiente_a_atender(lista)

    solo_agua = Necesidades.filtrar(lista, %{"tipo" => "agua", "zona" => "centro"})
    assert Enum.map(solo_agua, fn n -> n.id end) == ["N003", "N001"]
  end

  test "las transiciones de estado se validan y no se cierra dos veces" do
    zonas = Ayudas.zonas_de_prueba()
    {:ok, lista, _} = Necesidades.registrar_necesidad([], zonas, Ayudas.datos_necesidad("rescate", 1, "critica"))

    assert {:error, :transicion_invalida} = Necesidades.cambiar_estado(lista, "N001", "atendida")
    {:ok, lista, _} = Necesidades.cambiar_estado(lista, "N001", "en_atencion")
    {:ok, lista, _} = Necesidades.cambiar_estado(lista, "N001", "atendida")
    assert {:error, :necesidad_ya_cerrada} = Necesidades.cambiar_estado(lista, "N001", "cancelada")
  end

  # ---------------------------------------------------------------
  # Recursos e inventario
  # ---------------------------------------------------------------

  test "el inventario impide cantidades negativas y conserva el historial" do
    assert {:ok, _} = ServidorInventario.registrar_recurso(Ayudas.datos_recurso("R001", "agua", 50), "laura")
    assert {:error, :codigo_repetido} = ServidorInventario.registrar_recurso(Ayudas.datos_recurso("R001", "agua", 5), "laura")
    assert {:error, :cantidad_negativa} = ServidorInventario.registrar_recurso(Ayudas.datos_recurso("R002", "agua", -1), "laura")

    assert {:ok, %{cantidad: 70}} = ServidorInventario.registrar_entrada("R001", 20, "laura")
    assert {:error, :inventario_insuficiente} = ServidorInventario.registrar_salida("R001", 71, "laura")
    assert {:error, :cantidad_negativa} = ServidorInventario.registrar_salida("R001", -3, "laura")
    assert {:ok, %{cantidad: 60}} = ServidorInventario.registrar_salida("R001", 10, "laura")

    tipos = Enum.map(ServidorInventario.movimientos("R001"), fn m -> m.tipo end)
    assert tipos == [:entrada, :entrada, :salida]
  end

  test "transferir recursos entre centros de apoyo" do
    {:ok, _} = ServidorInventario.registrar_recurso(Ayudas.datos_recurso("R001", "agua", 200), "laura")

    assert {:error, :origen_incorrecto} = ServidorInventario.transferir("R001", "otro_centro", "albergue_2", 30, "", "laura")
    assert {:ok, "R001-albergue_2"} = ServidorInventario.transferir("R001", "centro_acopio_1", "albergue_2", 30, "", "laura")
    # La segunda transferencia al mismo destino suma al recurso que ya existe allí.
    assert {:ok, "R001-albergue_2"} = ServidorInventario.transferir("R001", "centro_acopio_1", "albergue_2", 20, "", "laura")

    assert {:ok, %{cantidad: 150}} = ServidorInventario.buscar_recurso("R001")
    assert {:ok, %{cantidad: 50, ubicacion: "albergue_2"}} = ServidorInventario.buscar_recurso("R001-albergue_2")
    assert ServidorInventario.disponibilidad("agua", "centro").total == 200
  end

  test "asignar recursos a una necesidad y no volver a consumir si está atendida" do
    zonas = Ayudas.zonas_de_prueba()
    {:ok, _} = ServidorInventario.registrar_recurso(Ayudas.datos_recurso("R001", "agua", 50), "laura")
    {:ok, lista, _} = Necesidades.registrar_necesidad([], zonas, Ayudas.datos_necesidad("agua", 30, "critica"))

    # Se asigna por categoría ("agua"), como en el comando assign_resource N001 agua 30.
    {:ok, lista, asignacion} = Necesidades.asignar_recurso(lista, "N001", "agua", 30, "laura")
    assert asignacion.restante == 20
    assert {:ok, %{estado: :asignada, asignada: 30}} = Necesidades.buscar(lista, "N001")

    # Ya está cubierta: pedir más supera lo que necesita.
    assert {:error, :cantidad_excede_necesidad} = Necesidades.asignar_recurso(lista, "N001", "agua", 1, "laura")

    {:ok, lista, _} = Necesidades.cambiar_estado(lista, "N001", "atendida")
    assert {:error, :necesidad_ya_atendida} = Necesidades.asignar_recurso(lista, "N001", "agua", 1, "laura")
    assert {:ok, %{cantidad: 20}} = ServidorInventario.buscar_recurso("R001")
  end

  # ---------------------------------------------------------------
  # Concurrencia
  # ---------------------------------------------------------------

  test "CONFLICTO CONCURRENTE: 50 unidades, dos procesos piden 30 y 25 al mismo tiempo" do
    zonas = Ayudas.zonas_de_prueba()
    {:ok, _} = ServidorInventario.registrar_recurso(Ayudas.datos_recurso("R001", "agua", 50), "laura")
    {:ok, lista, _} = Necesidades.registrar_necesidad([], zonas, Ayudas.datos_necesidad("agua", 30, "critica"))
    {:ok, lista, _} = Necesidades.registrar_necesidad(lista, zonas, Ayudas.datos_necesidad("agua", 25, "alta"))

    {lista, resultados} = SimuladorUsuarios.asignar_en_paralelo(lista, "R001", ["N001", "N002"], "laura")

    confirmadas = for {id, {:ok, a}} <- resultados, do: {id, a.cantidad}
    rechazadas = for {id, {:error, :inventario_insuficiente}} <- resultados, do: id

    # Solo una de las dos se puede cubrir con 50 unidades.
    assert length(confirmadas) == 1
    assert length(rechazadas) == 1

    total_entregado = Enum.reduce(confirmadas, 0, fn {_, c}, s -> s + c end)
    assert total_entregado <= 50

    {:ok, recurso} = ServidorInventario.buscar_recurso("R001")
    assert recurso.cantidad == 50 - total_entregado
    assert recurso.cantidad >= 0

    # La necesidad rechazada sigue pendiente.
    [id_rechazada] = rechazadas
    assert {:ok, %{estado: :pendiente, asignada: 0}} = Necesidades.buscar(lista, id_rechazada)
  end

  test "CONCURRENCIA MASIVA: 30 procesos piden 5 unidades de un inventario de 50" do
    {:ok, _} = ServidorInventario.registrar_recurso(Ayudas.datos_recurso("R001", "agua", 50), "laura")

    tareas =
      for i <- 1..30 do
        {"proceso_#{i}", fn -> ServidorInventario.asignar("R001", 5, "N#{i}", "prueba") end}
      end

    resultados = SimuladorUsuarios.ejecutar_en_paralelo(tareas)
    exitosas = Enum.count(resultados, fn {_, r} -> match?({:ok, _}, r) end)

    assert length(resultados) == 30
    assert exitosas == 10
    assert {:ok, %{cantidad: 0}} = ServidorInventario.buscar_recurso("R001")
  end

  test "CONCURRENCIA EN ALBERGUE: la ocupación nunca supera la capacidad" do
    datos = %{codigo: "A01", nombre: "Albergue Norte", zona: "zona_norte", capacidad: 5, ocupacion: 0}
    {:ok, _} = ServidorAlbergues.registrar_albergue(datos)

    documentos = for i <- 1..12, do: "doc#{i}"
    resultados = SimuladorUsuarios.ingresar_en_paralelo("A01", documentos)

    assert Enum.count(resultados, fn {_, r} -> match?({:ok, _}, r) end) == 5
    assert Enum.count(resultados, fn {_, r} -> r == {:error, :capacidad_superada} end) == 7

    {:ok, albergue} = ServidorAlbergues.consultar("A01")
    assert albergue.ocupacion == 5
    assert MapSet.size(albergue.personas) == 5
  end

  # ---------------------------------------------------------------
  # Albergues
  # ---------------------------------------------------------------

  test "ingresos, salidas, cupos y reporte de ocupación de albergues" do
    {:ok, _} = ServidorAlbergues.registrar_albergue(%{codigo: "A01", nombre: "Norte", zona: "zona_norte", capacidad: 2, ocupacion: 0})
    {:ok, _} = ServidorAlbergues.registrar_albergue(%{codigo: "A02", nombre: "Sur", zona: "centro", capacidad: 10, ocupacion: 1})
    assert {:error, :capacidad_superada} =
             ServidorAlbergues.registrar_albergue(%{codigo: "A03", nombre: "X", zona: "centro", capacidad: 2, ocupacion: 3})

    assert {:ok, _} = ServidorAlbergues.registrar_ingreso("A01", "111")
    assert {:error, :persona_ya_en_albergue} = ServidorAlbergues.registrar_ingreso("A01", "111")
    assert {:ok, %{ocupacion: 2} = lleno} = ServidorAlbergues.registrar_ingreso("A01", "222")
    assert Albergues.cupos_disponibles(lleno) == 0
    assert {:error, :capacidad_superada} = ServidorAlbergues.registrar_ingreso("A01", "333")

    assert [%{codigo: "A01", porcentaje: 100.0}, %{codigo: "A02"}] = ServidorAlbergues.reporte_ocupacion()

    assert {:ok, %{ocupacion: 1}} = ServidorAlbergues.registrar_salida("A01", "111")
    assert {:error, :persona_no_esta_en_albergue} = ServidorAlbergues.registrar_salida("A01", "111")
  end

  # ---------------------------------------------------------------
  # Personas y mensajes
  # ---------------------------------------------------------------

  test "registrar y buscar personas por documento, nombre, zona y estado" do
    zonas = Ayudas.zonas_de_prueba()
    datos = %{documento: "1094", nombre: "Andrés Pérez", edad: "30", zona: "zona_norte", estado: "localizada", usuario: "ana"}
    {:ok, personas, p} = Personas.registrar_persona([], zonas, datos)
    {:ok, personas, _} = Personas.registrar_persona(personas, zonas, %{datos | documento: "2000", nombre: "María", estado: "reportada"})

    assert p.id == "P001"
    assert {:error, :documento_repetido} = Personas.registrar_persona(personas, zonas, datos)
    assert {:ok, %{nombre: "Andrés Pérez"}} = Personas.buscar_por_documento(personas, "1094")
    assert [%{documento: "1094"}] = Personas.buscar(personas, :nombre, "andres")
    assert length(Personas.buscar(personas, :zona, "zona_norte")) == 2
    assert [%{documento: "2000"}] = Personas.buscar(personas, :estado, "reportada")
  end

  test "el historial de estados de una persona se conserva y se validan transiciones" do
    zonas = Ayudas.zonas_de_prueba()
    datos = %{documento: "1094", nombre: "Andrés", edad: 30, zona: "centro", estado: "localizada", usuario: "ana"}
    {:ok, personas, _} = Personas.registrar_persona([], zonas, datos)

    {:ok, personas, _} = Personas.cambiar_estado(personas, "1094", "en_albergue", "luis")
    {:ok, personas, p} = Personas.cambiar_estado(personas, "1094", "reunificada", "luis")
    assert Enum.map(p.historial, fn h -> h.nuevo end) == ["localizada", "en_albergue", "reunificada"]
    assert {:error, :persona_ya_reunificada} = Personas.cambiar_estado(personas, "1094", "localizada", "luis")
  end

  test "mensajes familiares: registrar, listar y marcar como entregados" do
    zonas = Ayudas.zonas_de_prueba()
    datos = %{documento: "1094", nombre: "Andrés", edad: 30, zona: "centro", estado: "localizada", usuario: "ana"}
    {:ok, personas, _} = Personas.registrar_persona([], zonas, datos)

    {:ok, mensajes, m} = MensajesFamiliares.registrar_mensaje([], personas, "ana", "persona", "1094", "Estoy bien")
    assert m.estado == :pendiente
    assert {:error, :persona_no_existe} = MensajesFamiliares.registrar_mensaje(mensajes, personas, "ana", "persona", "999", "Hola")
    {:ok, mensajes, _} = MensajesFamiliares.registrar_mensaje(mensajes, personas, "ana", "familia", "familia_perez", "Hola")

    assert [%{id: "MSG001"}] = MensajesFamiliares.listar_mensajes(mensajes, "1094")
    {:ok, mensajes, %{estado: :entregado}} = MensajesFamiliares.marcar_estado(mensajes, "MSG001", "entregado")
    assert {:error, :mensaje_ya_tiene_ese_estado} = MensajesFamiliares.marcar_estado(mensajes, "MSG001", "entregado")
  end

  # ---------------------------------------------------------------
  # Mascotas
  # ---------------------------------------------------------------

  test "coincidencias de mascotas con puntaje y cierre de ambos reportes" do
    zonas = Ayudas.zonas_de_prueba()

    base = %{tipo: "lost", especie: "perro", nombre: "Luna", caracteristicas: "collar rojo", color: "negra",
             tamano: "mediana", zona: "zona_norte", contacto: "300", reportado_por: "ana"}

    {:ok, mascotas, perdida} = Mascotas.registrar_reporte([], zonas, base)
    {:ok, mascotas, encontrada} = Mascotas.registrar_reporte(mascotas, zonas, %{base | tipo: "found", nombre: ""})
    {:ok, mascotas, _gato} = Mascotas.registrar_reporte(mascotas, zonas, %{base | tipo: "found", especie: "gato"})

    assert perdida.tipo == :perdida
    assert encontrada.nombre == "desconocido"
    assert Mascotas.calcular_similitud(perdida, encontrada) == 100

    {mascotas, coincidencias} = Mascotas.marcar_posibles_coincidencias(mascotas)
    # El gato no coincide con el perro (especie distinta -> 0 puntos).
    assert coincidencias == [%{perdida: "M001", encontrada: "M002", puntaje: 100}]
    assert {:ok, %{estado: :posible_coincidencia}} = Mascotas.buscar(mascotas, "M001")
    assert {:ok, %{estado: :activa}} = Mascotas.buscar(mascotas, "M003")

    {:ok, mascotas} = Mascotas.confirmar_coincidencia(mascotas, "M001", "M002")
    assert {:ok, %{estado: :resuelta, coincidencia: "M002"}} = Mascotas.buscar(mascotas, "M001")
    assert {:ok, %{estado: :resuelta}} = Mascotas.buscar(mascotas, "M002")
    assert {:error, :reporte_ya_resuelto} = Mascotas.confirmar_coincidencia(mascotas, "M001", "M002")
    # Los resueltos ya no aparecen como coincidencias.
    assert Mascotas.buscar_coincidencias(mascotas) == []
  end

  test "similitud parcial: mismo perro en otra zona y otro tamaño" do
    a = %{especie: "perro", color: "negra", tamano: "mediana", zona: "norte"}
    b = %{especie: "perro", color: "negra", tamano: "grande", zona: "sur"}
    c = %{especie: "perro", color: "blanca", tamano: "grande", zona: "sur"}
    assert Mascotas.calcular_similitud(a, b) == 65
    assert Mascotas.calcular_similitud(a, c) == 40
  end

  # ---------------------------------------------------------------
  # Persistencia y supervisión
  # ---------------------------------------------------------------

  test "persistencia: la información se guarda en texto plano y se recupera", %{carpeta: carpeta} do
    zonas = Ayudas.zonas_de_prueba()
    {:ok, zonas, _} = Zonas.registrar_sector(zonas, "centro", "S1", "Sector 1", "alto", 10)
    {:ok, zonas, _} = Zonas.registrar_punto(zonas, "centro", "S1", "P1", "Puesto | médico")
    Zonas.guardar(zonas)
    assert length(Zonas.cargar()) == 2
    {:ok, centro} = Zonas.buscar_zona(Zonas.cargar(), "centro")
    assert [%{codigo: "P1", nombre: "Puesto / médico"}] = Zonas.obtener_puntos(centro.sectores)

    {:ok, necesidades, _} = Necesidades.registrar_necesidad([], zonas, Ayudas.datos_necesidad("agua", 30, "critica"))
    Necesidades.guardar(necesidades)
    assert Necesidades.cargar() == necesidades

    datos = %{documento: "1094", nombre: "Andrés", edad: 30, zona: "centro", estado: "localizada", usuario: "ana"}
    {:ok, personas, _} = Personas.registrar_persona([], zonas, datos)
    {:ok, personas, _} = Personas.cambiar_estado(personas, "1094", "en_albergue", "luis")
    Personas.guardar(personas)
    assert Personas.cargar() == personas

    {:ok, _} = ServidorAlbergues.registrar_albergue(%{codigo: "A01", nombre: "Norte", zona: "centro", capacidad: 9, ocupacion: 0})
    {:ok, _} = ServidorAlbergues.registrar_ingreso("A01", "1094")
    assert [%{codigo: "A01", ocupacion: 1} = a] = Persistencia.cargar_albergues()
    assert MapSet.member?(a.personas, "1094")

    # Es texto plano legible.
    {:ok, contenido} = File.read(Path.join(carpeta, "necesidades.txt"))
    assert String.starts_with?(contenido, "N001|agua|prueba|30|0|centro|critica|laura|pendiente")
  end

  test "supervisor: si ServidorInventario falla se reinicia y recupera el inventario" do
    {:ok, _} = ServidorInventario.registrar_recurso(Ayudas.datos_recurso("R001", "agua", 50), "laura")

    {:ok, pid_anterior, pid_nuevo} = SupervisorEmergencia.simular_falla(ServidorInventario)
    assert pid_anterior != pid_nuevo
    assert {:ok, %{cantidad: 50}} = ServidorInventario.buscar_recurso("R001")

    # Los otros hijos no se reiniciaron (:one_for_one).
    assert length(SupervisorEmergencia.hijos()) == 3
  end

  test "supervisor: también reinicia el proceso de actividad (spawn_link)" do
    {:ok, anterior, nuevo} = SupervisorEmergencia.simular_falla(:proceso_actividad)
    assert anterior != nuevo
    Usuarios.registrar_actividad("laura", "despues del reinicio")
    assert [%{accion: "despues del reinicio"}] = Usuarios.consultar_actividad("laura")
  end

  test "las cantidades escritas en la consola (texto) se convierten a número" do
    # Desde la consola todo llega como texto: assign_resource N001 agua 20
    zonas = Ayudas.zonas_de_prueba()
    {:ok, _} = ServidorInventario.registrar_recurso(Ayudas.datos_recurso("R001", "agua", "50"), "laura")
    {:ok, lista, _} = Necesidades.registrar_necesidad([], zonas, Ayudas.datos_necesidad("agua", "30", "critica"))

    {:ok, lista, asignacion} = Necesidades.asignar_recurso(lista, "N001", "agua", "20", "laura")
    assert asignacion.cantidad == 20
    assert {:ok, %{asignada: 20}} = Necesidades.buscar(lista, "N001")
    assert {:error, :numero_invalido} = Necesidades.asignar_recurso(lista, "N001", "agua", "veinte", "laura")
    assert {:error, :cantidad_negativa} = Necesidades.asignar_recurso(lista, "N001", "agua", "-5", "laura")

    {:ok, _} = ServidorInventario.registrar_entrada("R001", "10", "laura")
    {:ok, _} = ServidorInventario.registrar_salida("R001", "5", "laura")
    {:ok, _} = ServidorInventario.transferir("R001", "centro_acopio_1", "albergue_2", "5", "", "laura")
    assert {:ok, %{cantidad: 30}} = ServidorInventario.buscar_recurso("R001")
    assert Enum.all?(ServidorInventario.movimientos(), fn m -> is_integer(m.cantidad) end)
  end

  test "interfaz: los comandos se separan en palabras respetando las comillas" do
    assert Interfaz.separar_palabras(~s(register_need agua 30 critica centro "Punto de atención sector 3")) ==
             ["register_need", "agua", "30", "critica", "centro", "Punto de atención sector 3"]

    assert Interfaz.separar_palabras(~s(connect laura 1234 coordinador centro\n)) ==
             ["connect", "laura", "1234", "coordinador", "centro"]

    assert Interfaz.separar_palabras("   ") == []
  end

  test "reportes: resumen y recursos críticos" do
    zonas = Ayudas.zonas_de_prueba()
    {:ok, _} = ServidorInventario.registrar_recurso(Ayudas.datos_recurso("R001", "agua", 20), "laura")
    {:ok, necesidades, _} = Necesidades.registrar_necesidad([], zonas, Ayudas.datos_necesidad("agua", 30, "critica"))

    criticos = Reportes.recursos_criticos(ServidorInventario.listar_recursos(), necesidades)
    assert [%{categoria: "agua", disponible: 20, demanda: 30, deficit: 10}] = criticos

    datos = %{zonas: zonas, necesidades: necesidades, personas: [], mensajes: [], mascotas: [],
              recursos: ServidorInventario.listar_recursos(), albergues: []}
    resumen = Reportes.resumen(datos)
    assert resumen.necesidades.pendientes == 1
    assert resumen.recursos.por_categoria == %{"agua" => 20}
  end
end
