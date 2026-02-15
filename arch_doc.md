# Архитектурный документ для "Мобильный мир"

## Задание 7. Проектирование схем коллекций для шардирования данных

### Коллекция Orders
```
{
    id: ObjectId, 
    user_id: ObjectId,
    created_at: Date,
    items: [
        {
            product_id: ObjectId, 
            price: Number,
            quantity: Number,
        }
    ],
    status: String,
    total: Number
    geo: String
}
```

**Shard key:**
user_id (hashed) - основная нагрузка будет при поиске истории заказов конкретного пользователя.

**Основные операции:**

1. Поиск истории заказов конкретного пользователя.

    ```
        db.orders.find({ user_id: ObjectId("USER_ID")}).sort({ createdAt: -1 });
    ```
2. Отображение статуса заказа.

    ```
        db.orders.find(
            { user_id: ObjectId("USER_ID")},
            { status: 1, total: 1, items: 1, _id: 0 })
        .sort({ createdAt: -1 });
    ```

### Коллекция Products
```
{
  id: ObjectId,
  name: String,        
  description: String, 
  price: Number,       
  stock: [
    {region: String, quantity: Number}
  ],       
  categories: [String],
  createdAt: Date,
  updatedAt: Date
  attributes: [String]
}
```

**Shard key:**
id (hashed) - остатки по регионам находятся прямо в коллекции, поэтому нет смысла шардировать по гео. Для поиска по категориям и цене можно использовать индексы. В дальнейшем можно выделить stocks в отдельную коллекцию для оптимизации поиска и более равномерного распределения данных по шардам.

**Основные операции:**

1. Обновления остатков при покупках.
    ```
        db.products.updateOne(
            { _id: ObjectId("..."), "stock.region": "..." },
            { $inc: { "stock.$.quantity": -2 } }
    );
    ```

2. Поиск товаров по категориям и фильтрация по диапазону цен.
    ```
        db.products.find(
            { categories: "electronics", price: { $gte: 200, $lte: 400 }},
            {
             name: 1,
             price: 1,
             categories: 1,
             _id: 0
            }
        )
        .sort({ createdAt: -1 });
    ```
3. Описание товара на странице продукта.
    ```
        db.orders.findOne(
            { id: ObjectId("...")},
            {
                name: 1,
                description: 1,
                price: 1,
                categories: 1,
                stock: 1,
                attributes: 1,
                id: 0
            }
        );
    ```

### Коллекция Carts
```
{
    id: ObjectId,
    user_id: ObjectId,
    session_id: ObjectId,
    items: [
        {
            product_id: ObjectId,
            quantity: Number
        }
    ],
    status: String,
    created_at: Date,
    updated_at: Date,
    expires_at: Date
}
```

**Shard key:**
user_id (hashed) - основная нагрузка - поиск корзины конкретного пользователя.

**Основные операции**

1. Создание корзины (гость или новый пользователь).
    ```
        db.carts.insertOne({
            user_id: null,                        
            session_id: "...",             
            status: "active",
            items: [],
            createdAt: new Date(),
            updatedAt: new Date()
        });
    ```
2. Получение текущей корзины по фильтру { session_id, status:"active" } или { user_id, status:"active" }.
    ```
        db.carts.findOne({
            user_id: ObjectId("..."),                        
            status: "active",
        });
    ```

3. Добавление или замена товара в корзине.
    ```
        db.carts.updateOne(
            { session_id: ObjectId("..."), status: "active" },
            {
              $set: { "items.$[elem]": { product_id: ObjectId("PROD_ID"), quantity: 3 } },
              $setOnInsert: { createdAt: new Date() },
              $currentDate: { updatedAt: true },
            },
            {
              arrayFilters: [{ "elem.product_id": ObjectId("PROD_ID") }]
            }
        );
    ```
4. Удаление товара из корзины.
    ```
        db.carts.delete(
            { session_id: ObjectId("..."), status: "active" },
            { $pull: { items: { product_id: ObjectId("PROD_ID") } },
                $currentDate: { updatedAt: true }
            }
        );
    ```
5. Отметка корзины как заказанной.
    ```
        db.carts.updateOne(
          { user_id: ObjectId("USER_ID"), status: "active" },
          { $set: { status: "ordered" }, $currentDate: { updatedAt: true } }
        );
    ```


## Задание 8. Выявление и устранение «горячих» шардов

Добавить мониторинг:

- Количество чанков по каждому шарду
- Количество запросов (read/write) на шард
- Средняя latency запросов
- CPU и RAM по каждому шард-серверу
- Частота встречаемости значений ключа

**Улучшение стратегии шардирования**

- Применять bucketing для популярных категорий. Использовать Shard key:
   ```js
       { category: "Электроника", bucket: hash(productId) % N }
   ```
- Применять zoned tag sharding по ключу region из массива stock.
  - Определить теги:
  ```
  tag1: {region: "Europe"}
  tag2: {region: "Asia"}
  ```
  - Создать зоны с тегами:
  ```
  zone1: { 
    stock.region: { 
      $gte: "A", 
      $lt: "M" 
    } 
  }
  zone2: { 
    stock.region: { 
      $gte: "M", 
      $lt: "Z" 
    } 
  }
  ```

**Метрики и алерты для предотвращения инцидентов**

- Дисбаланс чанков: если разница >20% между шардами.

- CPU: загрузка >70% более 5 минут.

- Latency: рост времени ответа >2х относительно среднего.

## Задание 9. Настройка чтения с реплик и консистентность

### Коллекция Products

- Primary
  - остатки
  - актуальная цена

**Причина:** Показываем актуальную цену. Продаем только то что есть в наличии.

- Secondary
  - описание товара

**Причина:** Описание товара меняется не часто. Допустима задержка.

**Допустимая задержка репликации:** 1..5 минут.

### Коллекция Orders

- Primary
  - статус заказа.

**Причина:** Необходимо показывать пользователю актуальный статус заказа (обработка, доставка, ...).

- Secondary
  - история заказов.

**Причина:** Допустимо показывать пользователю историю заказов с задержкой.

**Допустимая задержка репликации:** < 5 секунд.

### Коллекция Carts

- Primary
  - Запросы для бизнесс-логики (получение корзины пользователя, проверка остатков перед оплатой).

**Причина:** Недопустимо запускать операции оплаты на неактуальных данных. Недопустимо показывать пользователю устаревшие данные. 

- Secondary
  - Запросы для аналитики (кол-во заказов и общая выручка за день, заказанные товары за день, ...).

**Причина:** На больших выборках несоответствие в данных будет в пределах погрешности.

**Допустимая задержка репликации:** < 10 секунд.


## Задание 10. Миграция на Cassandra: модель данных, стратегии репликации и шардирования

Чтобы повысить отказоустойчивость и оптимизировать нагрузку мигрируем следующие коллекции на Casandra:

1. Carts - частая запись, скорость записи критична.

**Модель Carts**
```
CREATE TABLE carts (
    user_id uuid,
    session_id text,
    cart_id uuid,
    status text, 
    items list<frozen<item>>,  -- item = {product_id, quantity, added_at}
    created_at timestamp,
    updated_at timestamp,
    PRIMARY KEY ((user_id, session_id), cart_id)
) WITH CLUSTERING ORDER BY (cart_id ASC);
```

Partition key: (user_id, session_id)
Каждый пользователь/сессия → отдельная партиция → минимизируем конкуренцию и hot partitions.

Clustering key: cart_id
Позволяет хранить историю версий корзины, упорядоченно по времени.


**Цели**

- Максимально низкая latency для UX.
- Достаточная (но не абсолютная) согласованность для UI.
- Защититься от редких расхождений и конфликтов.

**Уровни консистентности**

- Обычные операции UI (просмотр/мелкие изменения):
  WRITE CL = LOCAL_ONE, READ CL = LOCAL_ONE — минимальная задержка.

- Фиксация статуса ordered:
  READ/WRITE CL = LOCAL_QUORUM.


**Hinted Handoff — включаем**

Кратковременные отказы реплик не бьют по UX, записи не теряются.

**Read Repair**

- На LOCAL_ONE read repair не задействуется - быстрый интерфейс.

- Для «контрольных» чтений (например, перед ordered) можно выполнить READ CL = LOCAL_QUORUM, что при необходимости подтянет отставшую реплику — дороже, но точечно и только в критический момент.

**Anti-Entropy Repair — по расписанию**

- carts более терпима к расхождениям. Достаточно ежедневного инкрементального repair (или даже реже, если подтверждённая метриками сходимость хорошая).

- Запускать off-peak и с ограничением ресурсов.

99% трафика — LOCAL_ONE (очень дёшево/быстро).
Редкие критичные шаги (merge/ordered) — LOCAL_QUORUM, где платим латентностью за корректность.