defmodule Recursos do
  @moduledoc """
  Funciones puras sobre la lista de recursos del inventario.

  Este módulo NO guarda estado: recibe la lista de recursos y devuelve una lista nueva.
  Quien guarda el estado compartido es el GenServer ServidorInventario, que llama a
  estas funciones dentro de sus handle_call. Así la validación y la modificación del
  inventario ocurren en un solo paso, sin que otra solicitud se meta en medio.

  Recurso:
      %{codigo: "R001", nombre: "Agua potable", categoria: "agua", cantidad: 50,
        unidad: "litros", ubicacion: "centro_acopio_1", zona: "centro"}

  Movimiento (historial):
      %{fecha: "...", tipo: :entrada, codigo: "R001", cantidad: 50, detalle: "...", usuario: "laura"}
  """

  # ---------------------------------------------------------------
  # Registro y búsqueda
  # ---------------------------------------------------------------

  # datos = %{codigo, nombre, categoria, cantidad, unidad, ubicacion, zona}
  def registrar_recurso(recursos, datos) do
    with {:ok, codigo} <- Utilidades.texto_requerido(datos.codigo, :codigo_vacio),
         {:ok, nombre} <- Utilidades.texto_requerido(datos.nombre, :nombre_vacio),
         {:ok, categoria} <- Utilidades.texto_requerido(datos.categoria, :categoria_vacia),
         {:ok, cantidad} <- Utilidades.a_cantidad(datos.cantidad),
         {:ok, unidad} <- Utilidades.texto_requerido(datos.unidad, :unidad_vacia),
         {:ok, ubicacion} <- Utilidades.texto_requerido(datos.ubicacion, :ubicacion_vacia),
         {:ok, zona} <- Utilidades.texto_requerido(datos.zona, :zona_vacia),
         {:error, :recurso_no_existe} <- buscar_recurso(recursos, codigo) do
      recurso = %{
        codigo: codigo,
        nombre: nombre,
        categoria: Utilidades.normalizar(categoria),
        cantidad: cantidad,
        unidad: unidad,
        ubicacion: ubicacion,
        zona: zona
      }

      {:ok, recursos ++ [recurso], recurso}
    else
      {:ok, %{codigo: _}} -> {:error, :codigo_repetido}
      error -> error
    end
  end

  def buscar_recurso(recursos, codigo) do
    case Enum.find(recursos, fn r -> r.codigo == codigo end) do
      nil -> {:error, :recurso_no_existe}
      recurso -> {:ok, recurso}
    end
  end

  # Disponibilidad por categoría y zona. Un filtro vacío ("") significa "cualquiera".
  def disponibilidad(recursos, categoria, zona) do
    encontrados =
      Enum.filter(recursos, fn r ->
        (categoria == "" or r.categoria == Utilidades.normalizar(categoria)) and
          (zona == "" or r.zona == zona)
      end)

    total = Enum.reduce(encontrados, 0, fn r, suma -> suma + r.cantidad end)
    %{recursos: encontrados, total: total}
  end

  # ---------------------------------------------------------------
  # Entradas y salidas (nunca se permiten cantidades negativas)
  # ---------------------------------------------------------------

  def registrar_entrada(recursos, codigo, cantidad) do
    with {:ok, cantidad} <- Utilidades.a_cantidad_positiva(cantidad),
         {:ok, recurso} <- buscar_recurso(recursos, codigo) do
      actualizado = %{recurso | cantidad: recurso.cantidad + cantidad}
      {:ok, reemplazar(recursos, actualizado), actualizado}
    end
  end

  def registrar_salida(recursos, codigo, cantidad) do
    with {:ok, cantidad} <- Utilidades.a_cantidad_positiva(cantidad),
         {:ok, recurso} <- buscar_recurso(recursos, codigo) do
      if cantidad > recurso.cantidad do
        # Si se descontara quedaría una cantidad negativa: se rechaza.
        {:error, :inventario_insuficiente}
      else
        actualizado = %{recurso | cantidad: recurso.cantidad - cantidad}
        {:ok, reemplazar(recursos, actualizado), actualizado}
      end
    end
  end

  # ---------------------------------------------------------------
  # Asignación a una necesidad
  # ---------------------------------------------------------------

  # La referencia puede ser el código de un recurso ("R001") o una categoría ("agua").
  # Si es una categoría se elige el primer recurso de esa categoría con cantidad suficiente.
  def seleccionar_recurso(recursos, referencia, cantidad) do
    case buscar_recurso(recursos, referencia) do
      {:ok, recurso} ->
        if recurso.cantidad >= cantidad, do: {:ok, recurso}, else: {:error, :inventario_insuficiente}

      {:error, :recurso_no_existe} ->
        categoria = Utilidades.normalizar(referencia)
        de_la_categoria = Enum.filter(recursos, fn r -> r.categoria == categoria end)
        elegir_con_cantidad(de_la_categoria, cantidad)
    end
  end

  # Recorre recursivamente los recursos de una categoría buscando uno con cantidad suficiente.
  defp elegir_con_cantidad([], _cantidad), do: {:error, :inventario_insuficiente}

  defp elegir_con_cantidad([recurso | resto], cantidad) do
    if recurso.cantidad >= cantidad do
      {:ok, recurso}
    else
      elegir_con_cantidad(resto, cantidad)
    end
  end

  # Valida y descuenta en el mismo paso. Devuelve {:ok, recursos_nuevos, recurso_actualizado}.
  def asignar(recursos, referencia, cantidad) do
    with {:ok, cantidad} <- Utilidades.a_cantidad_positiva(cantidad),
         {:ok, recurso} <- seleccionar_existente(recursos, referencia, cantidad) do
      registrar_salida(recursos, recurso.codigo, cantidad)
    end
  end

  defp seleccionar_existente(recursos, referencia, cantidad) do
    categoria = Utilidades.normalizar(referencia)
    existe_algo = Enum.any?(recursos, fn r -> r.codigo == referencia or r.categoria == categoria end)

    if existe_algo do
      seleccionar_recurso(recursos, referencia, cantidad)
    else
      {:error, :recurso_no_existe}
    end
  end

  # ---------------------------------------------------------------
  # Transferencia entre centros de apoyo
  # ---------------------------------------------------------------

  # Pasa una cantidad de un recurso desde su ubicación (origen) a otro centro (destino).
  # Si en el destino ya existe un recurso con el mismo nombre y categoría se le suma la cantidad;
  # si no existe, se crea uno nuevo con código "CODIGO-destino".
  # Devuelve {:ok, recursos_nuevos, codigo_destino}.
  def transferir(recursos, codigo, origen, destino, cantidad, zona_destino) do
    with {:ok, cantidad} <- Utilidades.a_cantidad_positiva(cantidad),
         {:ok, recurso} <- buscar_recurso(recursos, codigo),
         :ok <- validar_ubicaciones(recurso, origen, destino),
         {:ok, recursos_sin_salida, _} <- registrar_salida(recursos, codigo, cantidad) do
      case buscar_en_destino(recursos_sin_salida, recurso, destino) do
        {:ok, existente} ->
          actualizado = %{existente | cantidad: existente.cantidad + cantidad}
          {:ok, reemplazar(recursos_sin_salida, actualizado), existente.codigo}

        :no_existe ->
          zona = if zona_destino == "", do: recurso.zona, else: zona_destino
          nuevo = %{recurso | codigo: codigo <> "-" <> destino, cantidad: cantidad, ubicacion: destino, zona: zona}
          {:ok, recursos_sin_salida ++ [nuevo], nuevo.codigo}
      end
    end
  end

  defp validar_ubicaciones(recurso, origen, destino) do
    cond do
      recurso.ubicacion != origen -> {:error, :origen_incorrecto}
      String.trim(destino) == "" -> {:error, :destino_vacio}
      origen == destino -> {:error, :mismo_origen_destino}
      true -> :ok
    end
  end

  defp buscar_en_destino(recursos, recurso, destino) do
    encontrado =
      Enum.find(recursos, fn r ->
        r.ubicacion == destino and r.categoria == recurso.categoria and r.nombre == recurso.nombre
      end)

    case encontrado do
      nil -> :no_existe
      r -> {:ok, r}
    end
  end

  # ---------------------------------------------------------------
  # Historial de movimientos
  # ---------------------------------------------------------------

  # La cantidad puede llegar como texto desde la consola ("20"); en el historial se guarda como número.
  def crear_movimiento(tipo, codigo, cantidad, detalle, usuario) do
    numero =
      case Utilidades.a_entero(cantidad) do
        {:ok, n} -> n
        {:error, _} -> 0
      end

    %{fecha: Utilidades.fecha_actual(), tipo: tipo, codigo: codigo, cantidad: numero, detalle: detalle, usuario: usuario}
  end

  def movimientos_de(movimientos, ""), do: movimientos
  def movimientos_de(movimientos, codigo), do: Enum.filter(movimientos, fn m -> m.codigo == codigo end)

  defp reemplazar(recursos, recurso_nuevo) do
    Enum.map(recursos, fn r -> if r.codigo == recurso_nuevo.codigo, do: recurso_nuevo, else: r end)
  end
end
