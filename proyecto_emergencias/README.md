# Sistema Distribuido de Coordinación y Gestión de Emergencias en Elixir

Proyecto final de Programación III. Universidad del Quindío.
Sistema multiusuario por consola para coordinar la atención después de un terremoto.

## Cómo ejecutar

Desde la carpeta `proyecto_emergencias`:

```bash
elixir main.exs              # abre el sistema (intérprete de comandos)
elixir pruebas/pruebas.exs   # ejecuta las 29 pruebas
```

Al iniciar por primera vez se crea el usuario **admin / admin123** (rol administrador).
Los demás usuarios se registran solos la primera vez que usan `connect`.
Escriba `help` para ver los comandos que su rol puede usar.

Para empezar con los datos en blanco, vacía los archivos de `datos/`.

## Estructura

```
proyecto_emergencias/
├── main.exs                      # carga los módulos, inicia el supervisor y la interfaz
├── modulos/
│   ├── utilidades.exs            # validación de entradas, ids, fecha (apoyo común)
│   ├── persistencia.exs          # lectura/escritura de archivos .txt
│   ├── usuarios.exs              # registro, connect/disconnect, permisos, actividad
│   ├── zonas.exs                 # zona -> sectores -> puntos (funciones recursivas)
│   ├── necesidades.exs           # necesidades, prioridad, estados, asignación
│   ├── recursos.exs              # funciones puras del inventario
│   ├── personas.exs              # personas afectadas e historial de estados
│   ├── mensajes_familiares.exs   # mensajes entre familiares
│   ├── mascotas.exs              # mascotas perdidas/encontradas y similitud
│   ├── albergues.exs             # funciones puras de albergues
│   ├── reportes.exs              # resumen, recursos críticos, estadísticas
│   └── interfaz.exs              # intérprete de comandos (sin lógica de negocio)
├── procesos/
│   ├── servidor_inventario.exs   # GenServer del inventario compartido
│   ├── servidor_albergues.exs    # GenServer de ocupación de albergues
│   ├── proceso_actividad.exs     # proceso spawn/receive que escribe la bitácora
│   ├── simulador_usuarios.exs    # usuarios concurrentes con spawn/send/receive
│   └── supervisor_emergencia.exs # Supervisor :one_for_one
├── datos/                        # archivos de texto plano (persistencia)
└── pruebas/
    └── pruebas.exs               # pruebas con ExUnit
```

## Comandos

El sistema se usa escribiendo comandos, como en la sección 1.4.10 del enunciado.
Los textos con espacios van entre comillas. Los argumentos entre `[ ]` son opcionales.

Ejemplo (el flujo del enunciado):

```
connect laura 1234 coordinador centro "Laura Gómez"
register_zone centro Centro critico 100
register_need agua 30 critica centro "Punto de atención sector 3"
register_resource R001 agua 50 litros centro_acopio_1
assign_resource N001 agua 30
summary
```

**Comandos del enunciado** (mismos nombres):

| Comando | Uso |
|---|---|
| connect | `connect usuario contraseña [tipo zona "nombre completo"]` (si el usuario no existe se registra; si falta el nombre se pregunta) |
| disconnect | `disconnect` |
| register_zone | `register_zone codigo nombre nivel [personas]` |
| register_need | `register_need tipo cantidad prioridad zona descripcion [persona/familia/albergue referencia]` |
| list_needs | `list_needs [zona=.. tipo=.. prioridad=.. estado=..]` |
| assign_resource | `assign_resource necesidad recurso_o_categoria [cantidad]` (sin cantidad asigna lo que falta) |
| register_resource | `register_resource codigo categoria cantidad unidad ubicacion [zona] ["nombre"]` (zona por defecto: la del usuario) |
| list_resources | `list_resources [categoria=.. zona=..]` |
| transfer_resource | `transfer_resource codigo origen destino cantidad [zona_destino]` |
| report_person | `report_person documento nombre zona estado [edad]` (si falta la edad se pregunta) |
| find_person | `find_person documento` (muestra también su historial) o `find_person nombre=..` / `zona=..` / `estado=..` |
| send_family_message | `send_family_message documento "mensaje"` o `send_family_message familia:nombre "mensaje"` |
| list_family_messages | `list_family_messages documento` o `list_family_messages familia:nombre` |
| report_pet | `report_pet lost/found especie nombre color tamaño zona contacto ["caracteristicas"]` |
| match_pets | `match_pets` |
| register_shelter | `register_shelter codigo "nombre" zona capacidad [ocupacion]` |
| check_shelter | `check_shelter codigo` (sin código: reporte de albergues por ocupación) |
| register_entry / register_exit | `register_entry albergue documento` / `register_exit albergue documento` |
| summary / critical_resources / pending_needs | sin argumentos |

**Comandos adicionales**: solo los necesarios para requisitos del enunciado que no tenían comando sugerido.

| Comando | Uso | Requisito que cubre |
|---|---|---|
| register_sector | `register_sector zona codigo nombre nivel [personas]` | 1.4.3 Registrar zonas y sectores |
| register_point | `register_point zona sector codigo nombre` | 1.4.3 Zona → sectores → puntos de atención |
| zone_status | `zone_status zona` | 1.4.3 Estado general y estadísticas de una zona |
| need_status | `need_status necesidad estado` | 1.4.4 Estados de la necesidad (pendiente … atendida) |
| resource_in / resource_out | `resource_in codigo cantidad` / `resource_out codigo cantidad` | 1.4.5 Entradas y salidas de inventario |
| person_status | `person_status documento estado` | 1.4.6 Estados e historial de una persona |
| message_status | `message_status id entregado/pendiente` | 1.4.6 Marcar mensajes entregados o pendientes |
| list_pets | `list_pets [especie=.. zona=.. estado=..]` | 1.4.7 Consultar reportes de mascotas |
| confirm_match | `confirm_match id_perdida id_encontrada` | 1.4.7 Confirmar coincidencia y cerrar ambos reportes |
| activity | `activity [usuario]` (solo administrador) | 1.4.1 Actividad realizada por cada usuario |
| simulate_assign | `simulate_assign recurso N001 N002 ...` | Demostrar el conflicto concurrente (lista de verificación) |
| help / exit | ayuda y salir | Uso del programa |
