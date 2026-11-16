defmodule Persistencia do
  @moduledoc """
  Guarda y recupera la información en archivos de texto plano (carpeta datos/).

  Formato: cada registro ocupa una línea y sus campos se separan con "|".
  Cuando un campo contiene una lista (historial, documentos de un albergue)
  sus elementos se separan con ";" y las partes de cada elemento con ",".

  Ejemplo de una línea de necesidades.txt:
  N001|agua|Punto sector 3|30|0|centro|critica|laura|pendiente|zona|centro|2026-11-15 10:00:00
  """

  @separador "|"

  # ---------------------------------------------------------------
  # Funciones generales de archivos
  # ---------------------------------------------------------------

  # Carpeta de datos. Por defecto es "datos/" del proyecto.
  # Las pruebas la cambian con la variable de entorno EMERGENCIAS_DATOS para no tocar los datos reales.
  def directorio do
    case System.get_env("EMERGENCIAS_DATOS") do
      nil -> Path.expand("../datos", __DIR__)
      carpeta -> carpeta
    end
  end

  def ruta(nombre_archivo), do: Path.join(directorio(), nombre_archivo)

  # Lee un archivo y devuelve sus líneas. Si el archivo no existe devuelve una lista vacía.
  def leer_lineas(nombre_archivo) do
    case File.read(ruta(nombre_archivo)) do
      {:ok, contenido} -> String.split(contenido, ["\r\n", "\n"], trim: true)
      {:error, _motivo} -> []
    end
  end

  # Reemplaza todo el contenido del archivo con las líneas recibidas.
  def guardar_lineas(nombre_archivo, lineas) do
    File.mkdir_p(directorio())

    contenido =
      case lineas do
        [] -> ""
        _ -> Enum.join(lineas, "\n") <> "\n"
      end

    File.write(ruta(nombre_archivo), contenido)
  end

  # Agrega una línea al final del archivo (se usa para la bitácora de actividad).
  def agregar_linea(nombre_archivo, linea) do
    File.mkdir_p(directorio())
    File.write(ruta(nombre_archivo), linea <> "\n", [:append])
  end

  # Une los campos de un registro en una sola línea.
  def unir_campos(campos) do
    campos
    |> Enum.map(&limpiar/1)
    |> Enum.join(@separador)
  end

  # Separa una línea en sus campos.
  def separar_campos(linea), do: String.split(linea, @separador)

  # Evita que un texto del usuario rompa el formato del archivo.
  defp limpiar(valor) do
    valor
    |> to_string()
    |> String.replace(@separador, "/")
    |> String.replace("\n", " ")
    |> String.replace("\r", " ")
  end

  # Lee un archivo y convierte cada línea con la función recibida.
  # Las líneas que no se pueden convertir (dañadas) se ignoran.
  defp cargar_registros(nombre_archivo, convertir) do
    lineas = leer_lineas(nombre_archivo)

    Enum.reduce(lineas, [], fn linea, acumulado ->
      case convertir.(separar_campos(linea)) do
        nil -> acumulado
        registro -> [registro | acumulado]
      end
    end)
    |> Enum.reverse()
  end

  defp a_entero(texto) do
    case Integer.parse(texto) do
      {numero, _} -> numero
      :error -> 0
    end
  end

  defp a_atomo(texto), do: String.to_atom(texto)

  # ---------------------------------------------------------------
  # Usuarios: usuario|contrasena_cifrada|nombre|rol|zona
  # ---------------------------------------------------------------

  def guardar_usuarios(usuarios) do
    lineas =
      Enum.map(Map.values(usuarios), fn u ->
        unir_campos([u.usuario, u.contrasena, u.nombre, u.rol, u.zona])
      end)

    guardar_lineas("usuarios.txt", lineas)
  end

  # Devuelve un mapa usuario => datos del usuario.
  def cargar_usuarios do
    lista =
      cargar_registros("usuarios.txt", fn
        [usuario, contrasena, nombre, rol, zona] ->
          %{usuario: usuario, contrasena: contrasena, nombre: nombre, rol: a_atomo(rol), zona: zona}

        _ ->
          nil
      end)

    Enum.reduce(lista, %{}, fn u, mapa -> Map.put(mapa, u.usuario, u) end)
  end

  # ---------------------------------------------------------------
  # Zonas (estructura anidada guardada en tres tipos de línea)
  #   ZONA|codigo|nombre|nivel|personas
  #   SECTOR|codigo_zona|codigo|nombre|nivel|personas
  #   PUNTO|codigo_zona|codigo_sector|codigo|nombre
  # ---------------------------------------------------------------

  def guardar_zonas(zonas) do
    lineas =
      Enum.flat_map(zonas, fn zona ->
        linea_zona = unir_campos(["ZONA", zona.codigo, zona.nombre, zona.nivel, zona.personas_afectadas])

        lineas_sectores =
          Enum.flat_map(zona.sectores, fn sector ->
            linea_sector =
              unir_campos(["SECTOR", zona.codigo, sector.codigo, sector.nombre, sector.nivel, sector.personas_afectadas])

            lineas_puntos =
              Enum.map(sector.puntos, fn punto ->
                unir_campos(["PUNTO", zona.codigo, sector.codigo, punto.codigo, punto.nombre])
              end)

            [linea_sector | lineas_puntos]
          end)

        [linea_zona | lineas_sectores]
      end)

    guardar_lineas("zonas.txt", lineas)
  end

  def cargar_zonas do
    filas = Enum.map(leer_lineas("zonas.txt"), &separar_campos/1)

    zonas = for ["ZONA", codigo, nombre, nivel, personas] <- filas, do: {codigo, nombre, nivel, personas}
    sectores = for ["SECTOR", zona, codigo, nombre, nivel, personas] <- filas, do: {zona, codigo, nombre, nivel, personas}
    puntos = for ["PUNTO", zona, sector, codigo, nombre] <- filas, do: {zona, sector, codigo, nombre}

    # Se reconstruye la jerarquía zona -> sectores -> puntos de atención.
    Enum.map(zonas, fn {codigo_zona, nombre, nivel, personas} ->
      sectores_zona =
        for {^codigo_zona, codigo_sector, nombre_s, nivel_s, personas_s} <- sectores do
          puntos_sector =
            for {^codigo_zona, ^codigo_sector, codigo_p, nombre_p} <- puntos do
              %{codigo: codigo_p, nombre: nombre_p, sector: codigo_sector}
            end

          %{
            codigo: codigo_sector,
            nombre: nombre_s,
            nivel: a_atomo(nivel_s),
            personas_afectadas: a_entero(personas_s),
            puntos: puntos_sector
          }
        end

      %{
        codigo: codigo_zona,
        nombre: nombre,
        nivel: a_atomo(nivel),
        personas_afectadas: a_entero(personas),
        sectores: sectores_zona
      }
    end)
  end

  # ---------------------------------------------------------------
  # Necesidades:
  # id|tipo|descripcion|cantidad|asignada|zona|prioridad|responsable|estado|tipo_beneficiario|beneficiario|fecha
  # ---------------------------------------------------------------

  def guardar_necesidades(necesidades) do
    lineas =
      Enum.map(necesidades, fn n ->
        unir_campos([
          n.id, n.tipo, n.descripcion, n.cantidad, n.asignada, n.zona, n.prioridad,
          n.responsable, n.estado, n.tipo_beneficiario, n.beneficiario, n.fecha
        ])
      end)

    guardar_lineas("necesidades.txt", lineas)
  end

  def cargar_necesidades do
    cargar_registros("necesidades.txt", fn
      [id, tipo, descripcion, cantidad, asignada, zona, prioridad, responsable, estado, tipo_b, beneficiario, fecha] ->
        %{
          id: id,
          tipo: a_atomo(tipo),
          descripcion: descripcion,
          cantidad: a_entero(cantidad),
          asignada: a_entero(asignada),
          zona: zona,
          prioridad: a_atomo(prioridad),
          responsable: responsable,
          estado: a_atomo(estado),
          tipo_beneficiario: a_atomo(tipo_b),
          beneficiario: beneficiario,
          fecha: fecha
        }

      _ ->
        nil
    end)
  end

  # ---------------------------------------------------------------
  # Recursos: codigo|nombre|categoria|cantidad|unidad|ubicacion|zona
  # Movimientos: fecha|tipo|codigo|cantidad|detalle|usuario
  # ---------------------------------------------------------------

  def guardar_recursos(recursos) do
    lineas =
      Enum.map(recursos, fn r ->
        unir_campos([r.codigo, r.nombre, r.categoria, r.cantidad, r.unidad, r.ubicacion, r.zona])
      end)

    guardar_lineas("recursos.txt", lineas)
  end

  def cargar_recursos do
    cargar_registros("recursos.txt", fn
      [codigo, nombre, categoria, cantidad, unidad, ubicacion, zona] ->
        %{
          codigo: codigo,
          nombre: nombre,
          categoria: categoria,
          cantidad: a_entero(cantidad),
          unidad: unidad,
          ubicacion: ubicacion,
          zona: zona
        }

      _ ->
        nil
    end)
  end

  def guardar_movimientos(movimientos) do
    lineas =
      Enum.map(movimientos, fn m ->
        unir_campos([m.fecha, m.tipo, m.codigo, m.cantidad, m.detalle, m.usuario])
      end)

    guardar_lineas("movimientos.txt", lineas)
  end

  def cargar_movimientos do
    cargar_registros("movimientos.txt", fn
      [fecha, tipo, codigo, cantidad, detalle, usuario] ->
        %{fecha: fecha, tipo: a_atomo(tipo), codigo: codigo, cantidad: a_entero(cantidad), detalle: detalle, usuario: usuario}

      _ ->
        nil
    end)
  end

  # ---------------------------------------------------------------
  # Personas: id|documento|nombre|edad|zona|estado|historial
  # historial = "fecha,anterior,nuevo,usuario;fecha,anterior,nuevo,usuario"
  # ---------------------------------------------------------------

  def guardar_personas(personas) do
    lineas =
      Enum.map(personas, fn p ->
        historial =
          p.historial
          |> Enum.map(fn h -> Enum.join([h.fecha, h.anterior, h.nuevo, h.usuario], ",") end)
          |> Enum.join(";")

        unir_campos([p.id, p.documento, p.nombre, p.edad, p.zona, p.estado, historial])
      end)

    guardar_lineas("personas.txt", lineas)
  end

  def cargar_personas do
    cargar_registros("personas.txt", fn
      [id, documento, nombre, edad, zona, estado, historial] ->
        %{
          id: id,
          documento: documento,
          nombre: nombre,
          edad: a_entero(edad),
          zona: zona,
          estado: a_atomo(estado),
          historial: leer_historial(historial)
        }

      _ ->
        nil
    end)
  end

  defp leer_historial(texto) do
    texto
    |> String.split(";", trim: true)
    |> Enum.map(fn entrada ->
      case String.split(entrada, ",") do
        [fecha, anterior, nuevo, usuario] -> %{fecha: fecha, anterior: anterior, nuevo: nuevo, usuario: usuario}
        _ -> nil
      end
    end)
    |> Enum.reject(&is_nil/1)
  end

  # ---------------------------------------------------------------
  # Mensajes: id|fecha|remitente|tipo_destinatario|destinatario|contenido|estado
  # ---------------------------------------------------------------

  def guardar_mensajes(mensajes) do
    lineas =
      Enum.map(mensajes, fn m ->
        unir_campos([m.id, m.fecha, m.remitente, m.tipo_destinatario, m.destinatario, m.contenido, m.estado])
      end)

    guardar_lineas("mensajes.txt", lineas)
  end

  def cargar_mensajes do
    cargar_registros("mensajes.txt", fn
      [id, fecha, remitente, tipo_destinatario, destinatario, contenido, estado] ->
        %{
          id: id,
          fecha: fecha,
          remitente: remitente,
          tipo_destinatario: a_atomo(tipo_destinatario),
          destinatario: destinatario,
          contenido: contenido,
          estado: a_atomo(estado)
        }

      _ ->
        nil
    end)
  end

  # ---------------------------------------------------------------
  # Mascotas:
  # id|tipo|especie|nombre|caracteristicas|color|tamano|zona|contacto|estado|coincidencia|reportado_por
  # ---------------------------------------------------------------

  def guardar_mascotas(mascotas) do
    lineas =
      Enum.map(mascotas, fn m ->
        unir_campos([
          m.id, m.tipo, m.especie, m.nombre, m.caracteristicas, m.color, m.tamano,
          m.zona, m.contacto, m.estado, m.coincidencia, m.reportado_por
        ])
      end)

    guardar_lineas("mascotas.txt", lineas)
  end

  def cargar_mascotas do
    cargar_registros("mascotas.txt", fn
      [id, tipo, especie, nombre, caracteristicas, color, tamano, zona, contacto, estado, coincidencia, reportado_por] ->
        %{
          id: id,
          tipo: a_atomo(tipo),
          especie: especie,
          nombre: nombre,
          caracteristicas: caracteristicas,
          color: color,
          tamano: tamano,
          zona: zona,
          contacto: contacto,
          estado: a_atomo(estado),
          coincidencia: coincidencia,
          reportado_por: reportado_por
        }

      _ ->
        nil
    end)
  end

  # ---------------------------------------------------------------
  # Albergues: codigo|nombre|zona|capacidad|ocupacion|documentos
  # documentos = "doc1;doc2;doc3" (se reconstruye como MapSet)
  # ---------------------------------------------------------------

  def guardar_albergues(albergues) do
    lineas =
      Enum.map(albergues, fn a ->
        documentos = Enum.join(MapSet.to_list(a.personas), ";")
        unir_campos([a.codigo, a.nombre, a.zona, a.capacidad, a.ocupacion, documentos])
      end)

    guardar_lineas("albergues.txt", lineas)
  end

  def cargar_albergues do
    cargar_registros("albergues.txt", fn
      [codigo, nombre, zona, capacidad, ocupacion, documentos] ->
        %{
          codigo: codigo,
          nombre: nombre,
          zona: zona,
          capacidad: a_entero(capacidad),
          ocupacion: a_entero(ocupacion),
          personas: MapSet.new(String.split(documentos, ";", trim: true))
        }

      _ ->
        nil
    end)
  end

  # ---------------------------------------------------------------
  # Actividad de usuarios (bitácora): fecha|usuario|accion
  # ---------------------------------------------------------------

  def registrar_actividad(usuario, accion) do
    agregar_linea("actividad.txt", unir_campos([Utilidades.fecha_actual(), usuario, accion]))
  end

  def cargar_actividad do
    cargar_registros("actividad.txt", fn
      [fecha, usuario, accion] -> %{fecha: fecha, usuario: usuario, accion: accion}
      _ -> nil
    end)
  end
end
