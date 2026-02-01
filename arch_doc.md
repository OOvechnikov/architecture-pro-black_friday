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

**Причина:** Необходимо для правильной бизнесс-логики.

- Secondary
  - история заказов.

**Причина:** Нет риска ошибки в бизнесс-логике.

**Допустимая задержка репликации:** < 5 секунд.

### Коллекция Carts

- Primary
  - Запросы для бизнесс-логики.

**Причина:** Недопустимо запускать операции оплаты на неактуальных данных. Недопустимо показывать пользователю устаревшие данные. 

- Secondary
  - Запросы для метрик (в том числе бизнесс).

**Причина:** На больхих выборках несоответствие в данныхз будет в пределах погрешности.

**Допустимая задержка репликации:** < 10 секунд.


## Задание 10. Миграция на Cassandra: модель данных, стратегии репликации и шардирования

Чтобы повысить отказоустойчивость и оптимизировать нагрузку мигрируем следующие коллекции на Casandra:

1. Products - выделим stocks в отдельную сущность и перенесем в casandra, т.к эти данные часто обновляются и для шарда с популярными продуктами может возникать перегрев. Products оставим в mongo и будем кэшировать эти данные. Пересмотрим стратегию шардирования для products чтобы избежать перегрева шардов.
2. Stocks - часто читаются, частая запись остатков по регионам. Нужно горизонтальное масштабирование без полного перераспределения данных.
3. Carts - частая запись, скорость записи критична.

**Модель Stocks**
```
CREATE TABLE product_stocks (
    product_id uuid,
    region text,
    quantity int,
    updated_at timestamp,
    PRIMARY KEY ((region), product_id)
);
```

Partition key: region

Гарантирует, что остатки в одном регионе хранятся в одной партиции. Нагрузка равномерно распределяется по кластерам, потому что у нас много регионов и
каждый region уходит на разные узлы.

Clustering key: product_id

Внутри региона мы храним остатки по продуктам

**Цели**

- Исключить oversell.
- Держать низкую задержку при экстремальной записи.
- Быстро выравнивать расхождения после кратких сбоев.

**Уровни консистентности**

- Критичный путь (резерва/списание): WRITE CL = QUORUM + READ CL = QUORUM

- Некритичное чтение для UI/поиска: READ CL = LOCAL_ONE (можно с кэшем) — допустима краткая неконсистентность данных.

**Hinted Handoff — включаем**

- Помогает переживать краткие отказы реплик без «дыр» в остатках.

- Настроить лимиты (объём/скорость хинтов), чтобы не забить диск и сеть при длительных сбоях.


**Read Repair**

- На критичных чтениях с CL=QUORUM расхождения будут обнаруживаться и чиниться в момент чтения. Это повышает свежесть данных там где это важно (checkout) в обмен на небольшой рост latency именно этих чтений.

- На чтениях LOCAL_ONE (UI) read repair не срабатывает. UI остаётся быстрым, а «подтягивание» консистентности мы делаем вне этого пути.


**Anti-Entropy Repair — по расписанию**

- Инкрементальный repair 1–2 раза в сутки (или чаще при больших write-объёмах), строго off-peak.

- Разнести по DC/шардам, ограничить параллелизм чтобы не трогать прод в пик.

- Это снимает накопленные расхождения, которые не поймал read repair (особенно после длительных отказов).


На самом важном пути (списание) мы сознательно платим за QUORUM/LWT чтобы не было oversell.

Везде вне критического пути — дешёвые LOCAL_ONE + кэш, а целостность поддерживаем Hinted Handoff и плановыми repair.

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