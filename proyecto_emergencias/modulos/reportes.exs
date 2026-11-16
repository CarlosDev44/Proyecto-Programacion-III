defmodule Reportes do
  @moduledoc """
  Resúmenes y estadísticas. Son funciones puras: reciben las listas y devuelven mapas.
  Los recursos y albergues se obtienen antes desde sus GenServer y se pasan como parámetro.
  """

  # Un recurso individual con esta cantidad o menos se considera crítico.
  @umbral_recurso_critico 10

  def umbral_recurso_critico, do: @umbral_recurso_critico

  # Cuenta cuántos elementos hay por cada valor de un campo. Ej: %{pendiente: 3, atendida: 1}
  def contar_por(lista, campo) do
    Enum.reduce(lista, %{}, fn elemento, conteo ->
      valor = Map.get(elemento, campo)
      Map.update(conteo, valor, 1, fn actual -> actual + 1 end)
    end)
  end

  # Resumen global (comando summary).
  # datos = %{necesidades, recursos, personas, mensajes, mascotas, albergues, zonas}
  def resumen(datos) do
    recursos_por_categoria =
      Enum.reduce(datos.recursos, %{}, fn r, mapa ->
        Map.update(mapa, r.categoria, r.cantidad, fn total -> total + r.cantidad end)
      end)

    %{
      zonas: length(datos.zonas),
      necesidades: %{
        total: length(datos.necesidades),
        por_estado: contar_por(datos.necesidades, :estado),
        pendientes: length(Necesidades.pendientes(datos.necesidades))
      },
      recursos: %{
        total_registros: length(datos.recursos),
        por_categoria: recursos_por_categoria
      },
      personas: %{
        total: length(datos.personas),
        por_estado: contar_por(datos.personas, :estado),
        localizadas: length(Enum.filter(datos.personas, fn p -> p.estado != :sin_informacion and p.estado != :reportada end))
      },
      mensajes: %{
        total: length(datos.mensajes),
        por_estado: contar_por(datos.mensajes, :estado)
      },
      mascotas: %{
        total: length(datos.mascotas),
        por_tipo: contar_por(datos.mascotas, :tipo),
        por_estado: contar_por(datos.mascotas, :estado)
      },
      albergues: %{
        total: length(datos.albergues),
        capacidad_total: Enum.reduce(datos.albergues, 0, fn a, s -> s + a.capacidad end),
        ocupacion_total: Enum.reduce(datos.albergues, 0, fn a, s -> s + a.ocupacion end)
      }
    }
  end

  # Recursos críticos (comando critical_resources). Una categoría es crítica cuando:
  # - lo disponible no alcanza para cubrir lo que falta en las necesidades abiertas, o
  # - lo disponible es menor o igual al umbral (10 unidades).
  def recursos_criticos(recursos, necesidades) do
    disponible = Enum.reduce(recursos, %{}, fn r, m -> Map.update(m, r.categoria, r.cantidad, &(&1 + r.cantidad)) end)

    demanda =
      Enum.reduce(Necesidades.pendientes(necesidades), %{}, fn n, m ->
        faltante = Necesidades.cantidad_faltante(n)
        Map.update(m, Atom.to_string(n.tipo), faltante, &(&1 + faltante))
      end)

    categorias = Enum.uniq(Map.keys(disponible) ++ Map.keys(demanda))

    categorias
    |> Enum.map(fn categoria ->
      stock = Map.get(disponible, categoria, 0)
      requerido = Map.get(demanda, categoria, 0)
      %{categoria: categoria, disponible: stock, demanda: requerido, deficit: max(requerido - stock, 0)}
    end)
    |> Enum.filter(fn c -> c.disponible < c.demanda or c.disponible <= @umbral_recurso_critico end)
    |> Enum.sort_by(fn c -> c.deficit end, :desc)
  end

  # Necesidades pendientes ordenadas por prioridad (comando pending_needs).
  def necesidades_pendientes(necesidades), do: Necesidades.pendientes(necesidades)

  # Estado general de una zona: estadísticas recursivas + elementos asociados a la zona.
  def estado_zona(zona, datos) do
    codigo = zona.codigo

    %{
      estadisticas: Zonas.estadisticas_zona(zona),
      necesidades: contar_por(Enum.filter(datos.necesidades, fn n -> n.zona == codigo end), :estado),
      recursos: Enum.filter(datos.recursos, fn r -> r.zona == codigo end),
      albergues: Enum.filter(datos.albergues, fn a -> a.zona == codigo end),
      personas: length(Enum.filter(datos.personas, fn p -> p.zona == codigo end)),
      mascotas: length(Enum.filter(datos.mascotas, fn m -> m.zona == codigo end))
    }
  end

  # Detalle de un albergue con los recursos ubicados allí y las necesidades asociadas a él.
  def detalle_albergue(albergue, recursos, necesidades) do
    %{
      albergue: albergue,
      cupos: Albergues.cupos_disponibles(albergue),
      porcentaje: Albergues.calcular_ocupacion(albergue),
      recursos: Enum.filter(recursos, fn r -> r.ubicacion == albergue.codigo end),
      necesidades:
        Enum.filter(necesidades, fn n -> n.tipo_beneficiario == :albergue and n.beneficiario == albergue.codigo end)
    }
  end
end
