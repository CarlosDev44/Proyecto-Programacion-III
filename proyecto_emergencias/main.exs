# Punto de entrada del sistema.
# Ejecutar desde la carpeta proyecto_emergencias con:   elixir main.exs

# 1. Carga explícita de los módulos (sin Mix).
#    El orden importa: cada archivo se carga después de los módulos que utiliza.
#    - Utilidades y Persistencia no dependen de nadie.
#    - Los GenServer usan las funciones puras de Recursos y Albergues.
#    - Usuarios y Necesidades llaman a los procesos, por eso van después de ellos.
#    - La interfaz se carga al final porque usa todo lo anterior.
Code.require_file("modulos/utilidades.exs", __DIR__)
Code.require_file("modulos/persistencia.exs", __DIR__)
Code.require_file("modulos/zonas.exs", __DIR__)
Code.require_file("modulos/recursos.exs", __DIR__)
Code.require_file("modulos/albergues.exs", __DIR__)

Code.require_file("procesos/proceso_actividad.exs", __DIR__)
Code.require_file("procesos/servidor_inventario.exs", __DIR__)
Code.require_file("procesos/servidor_albergues.exs", __DIR__)

Code.require_file("modulos/usuarios.exs", __DIR__)
Code.require_file("modulos/necesidades.exs", __DIR__)
Code.require_file("modulos/personas.exs", __DIR__)
Code.require_file("modulos/mensajes_familiares.exs", __DIR__)
Code.require_file("modulos/mascotas.exs", __DIR__)
Code.require_file("modulos/reportes.exs", __DIR__)

Code.require_file("procesos/simulador_usuarios.exs", __DIR__)
Code.require_file("procesos/supervisor_emergencia.exs", __DIR__)

Code.require_file("modulos/interfaz.exs", __DIR__)

# 2. Se inicia el supervisor, que a su vez inicia ProcesoActividad,
#    ServidorInventario y ServidorAlbergues (cargando sus datos de los archivos).
{:ok, _pid} = SupervisorEmergencia.start_link()

# 3. Se abre el menú por consola.
Interfaz.iniciar()
