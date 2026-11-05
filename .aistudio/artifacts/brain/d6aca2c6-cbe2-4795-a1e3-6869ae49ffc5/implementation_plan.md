# Store Manager Pro — v0.4 Final Consistency Corrections (C2)
## الملحق الهندسي الأخير — تصحيح الاتساق الحسابي والبياني والتشغيلي
**الحالة:** ملحق نهائي ملزم ومكمل للوثيقة v0.4 والملحق C1  
**الدور الهندسي:** Principal Software Architect, Database Architect & Financial Systems Specialist  
**الهدف:** تصحيح التناقضات المتبقية في C1، توحيد المقاييس الحسابية، إثبات المخطط البرمجي على محرك SQLite، وتقديم المعمارية النهائية الصارمة الجاهزة للبدء التجريبي.

---

## 1. ملخص التصحيحات والتغييرات (C1 → C2 Change Log)

| البند | الوضع في C1 | التصحيح النهائي في C2 | المبرر الفني والرياضي |
| :--- | :--- | :--- | :--- |
| **عدد الجداول الفعلي** | ذكر 28 جدولاً بينما الكود يحتوي 42. | **تصحيح العدد رسمياً وتوثيقه بدقة: 42 جدولاً** تم فحصها وتشغيلها فعلياً على SQLite 3.40.1. | الشفافية التامة ومطابقة التوثيق للمخطط الحقيقي المنفذ. |
| **معادلة المبلغ بالسنتيم** | استخدام مقام $100,000,000$ (خطأ بمقدار 100 ضعف). | **تصحيح المقام إلى $1,000,000$ مع تقريب Half-Up:**<br>$\text{Centimes} = \lfloor (\text{PriceTicks} \times \text{QuantityTicks} + 500,000) / 1,000,000 \rfloor$. | مطابقة وحدات القياس: PriceTicks ($10^4$) × QuantityTicks ($10^4$) ينتج $10^8$، والتحويل إلى سنتيم ($10^2$) يتطلب القسمة على $10^6$. |
| **المتجه المرجعي (Test Vector)** | نتائج عددية غير متسقة مع معادلة C1 السابقة. | **إثبات ومطابقة المتجه المرجعي بنسبة 100%:**<br>السعر 250 دج، الكمية 1.375 كغ، الخصم 5%، الضريبة 19% $\rightarrow$ **الإجمالي: 38,861 سنتيم (388.61 دج)**. | اختبار حسابي معياري ثابت وموحد لكافة المنصات. |
| **علاقة المتجر بالمستودع** | عدم وجود ربط صريح بين المستودعات والمتجر. | إضافة `warehouses.store_id` مع قيد `UNIQUE` للمستودع الافتراضي الواحد لكل متجر. | فرض سلامة ملكية البيانات ومنع تعدد المستودعات الافتراضية. |
| **أبعاد وحدات القياس** | تحويل مجرد بدون فحص التوافق الفيزيائي. | إضافة حقل `dimension` (`COUNT`, `WEIGHT`, `VOLUME`, `LENGTH`) لمنع تحويل أبعاد متعارضة (مثل كغ إلى متر). | منع تشوه المخزون والحسابات عند إدخال تحويلات خاطئة. |
| **تناقض إنشاء المنتجات** | الإشارة إلى `current_moving_avg_cost` في `stock_items`. | تأكيد إنشاء المنتج بالاسم وحده وربطه بـ `UOM_PIECE`، ونقل MAC إلى `inventory_balances` حصراً. | انسجام كامل بين منطق العمل وطبقة البيانات. |
| **تتبع استهلاك الحصص** | قيود عامة في DDL فقط. | توثيق دورة الحصص الذرية: $Available = OnHand - Reserved$ ومعالجة فقدان الأجهزة والتسوية الجزئية. | منع الخصم المزدوج للمخزون أو تحرير كميات لم تسوَّ. |
| **هوية الدفتر المالي** | وصف غامض بالـ Double-Entry. | **توصيف صريح: Party Account Ledger (دفتر ذمم الأطراف)** مع تحديد إشارات العمليات ومصدر الحدث الفريد. | التزام تام بالواقع المحاسبي ومنع التضليل الهندسي. |

---

## 2. الدقة المالية الصارمة والمعادلات الرياضية (Financial Precision & Math)

### 2.1 تعريف المقاييس والوحدات (Data Types & Scales)
1. **`Money`:** مخزن كـ `Long` بوحدة **السنتيم** (100 سنتيم = 1 دج). المدى: $-9 \times 10^{15}$ إلى $+9 \times 10^{15}$ سنتيم.
2. **`UnitPrice` (`PriceTicks`):** مخزن كـ `Long` بوحدة أجزاء من 1/10,000 دينار (القيمة المخزنة = السعر بالدينار $\times 10,000$). مثال: $250.00$ دج $\rightarrow 2,500,000 \text{ ticks}$.
3. **`Quantity` (`QuantityTicks`):** مخزن كـ `Long` بوحدة أجزاء من 1/10,000 من الوحدة الأساسية (القيمة المخزنة = الكمية $\times 10,000$). مثال: $1.375$ كغ $\rightarrow 13,750 \text{ ticks}$.
4. **`BasisPoints`:** مخزن كـ `INTEGER` ($100 \text{ bps} = 1.00\%$, $10000 \text{ bps} = 100.00\%$).

### 2.2 المعادلة المصححة للمبلغ بالسنتيم
$$\text{AmountCentimes} = \left\lfloor \frac{\text{PriceTicks} \times \text{QuantityTicks} + 500,000}{1,000,000} \right\rfloor$$
- **الإثبات الرياضي:**
  $$\text{PriceTicks} \times \text{QuantityTicks} = (\text{Price}_{\text{DZD}} \times 10^4) \times (\text{Qty} \times 10^4) = \text{Amount}_{\text{DZD}} \times 10^8$$
  بما أن $1 \text{ DZD} = 100 \text{ Centimes} = 10^2 \text{ Centimes}$، فإن:
  $$\text{Amount}_{\text{Centimes}} = \frac{\text{Amount}_{\text{DZD}} \times 10^8}{10^6} = \frac{\text{PriceTicks} \times \text{QuantityTicks}}{1,000,000}$$
  إضافة $500,000$ تمثل إضافة نصف المقام ($1,000,000 / 2$) لتحقيق تقريب **Half-Up** الرياضي الدقيق باستخدام الأعداد الصحيحة غير السالبة.

### 2.3 المتجه المرجعي الإلزامي (Reference Test Vector)
- **المدخلات:**
  - $\text{PriceTicks} = 2,500,000$ ($250.00$ DZD/kg)
  - $\text{QuantityTicks} = 13,750$ ($1.375$ kg)
  - $\text{DiscountBasisPoints} = 500$ ($5.00\%$)
  - $\text{TaxBasisPoints} = 1900$ ($19.00\%$)
  - السعر غير شامل للضريبة.
- **الحسابات والنتائج:**
  1. $\text{SubtotalCentimes} = \lfloor (2,500,000 \times 13,750 + 500,000) / 1,000,000 \rfloor = \mathbf{34,375} \text{ centimes}$ ($343.75$ دج).
  2. $\text{DiscountCentimes} = \lfloor (34,375 \times 500 + 5,000) / 10,000 \rfloor = \mathbf{1,719} \text{ centimes}$ ($17.19$ دج).
  3. $\text{NetCentimes} = 34,375 - 1,719 = \mathbf{32,656} \text{ centimes}$ ($326.56$ دج).
  4. $\text{TaxCentimes} = \lfloor (32,656 \times 1900 + 5,000) / 10,000 \rfloor = \mathbf{6,205} \text{ centimes}$ ($62.05$ دج).
  5. $\text{TotalLineAmountCentimes} = 32,656 + 6,205 = \mathbf{38,861} \text{ centimes}$ ($388.61$ دج).
  *(تم اختبار وتشغيل هذه المعادلة برمجياً ومطابقتها 100%)*.

### 2.4 ترتيب الحساب وحالة السعر الشامل للضريبة
- **للسعر غير الشامل للضريبة (Exclusive):**
  $$\text{Net} = \text{Subtotal} - \text{Discount}$$
  $$\text{Tax} = \text{RoundHalfUp}\left( \frac{\text{Net} \times \text{TaxBps}}{10000} \right)$$
  $$\text{TotalLine} = \text{Net} + \text{Tax}$$
- **للسعر الشامل للضريبة (Inclusive):**
  $$\text{EffectiveGross} = \text{Subtotal} - \text{Discount}$$
  $$\text{Net} = \text{RoundHalfUp}\left( \frac{\text{EffectiveGross} \times 10000}{10000 + \text{TaxBps}} \right)$$
  $$\text{Tax} = \text{EffectiveGross} - \text{Net}$$
  $$\text{TotalLine} = \text{EffectiveGross}$$
- **إجمالي الفاتورة:** $\text{InvoiceTotal} = \sum \text{TotalLine}$؛ لا يتم حساب الضريبة أو الخصم بتجميع النسب على مستوى الفاتورة لتفادي أي فروقات تجميعية مع سطور الفاتورة.

### 2.5 منع طفح الأرقام (Overflow Prevention)
- أقصى قيمة لـ $\text{PriceTicks} \times \text{QuantityTicks}$ في معاملة واحدة:
  إذا كان السعر الأقصى 100 مليون دج ($10^{12} \text{ ticks}$) والكمية القصوى مليون ($10^{10} \text{ ticks}$)، فإن الناتج $10^{22}$ يتجاوز نطاق `Long.MAX_VALUE` ($9.22 \times 10^{18}$).
- **الحل المعتمد في Kotlin:** تنفيذ الضرب الأولي باستخدام `BigInteger` أو استخدام دالة آمنة تفحص الحدود:
  ```kotlin
  fun calculateLineSubtotal(priceTicks: Long, quantityTicks: Long): Long {
      require(priceTicks >= 0 && quantityTicks >= 0) { "Values must be non-negative" }
      // إذا تجاوز حاصل الضرب Long.MAX_VALUE - 500_000
      val product = BigInteger.valueOf(priceTicks).multiply(BigInteger.valueOf(quantityTicks))
      val withHalfUp = product.add(BigInteger.valueOf(500_000L))
      return withHalfUp.divide(BigInteger.valueOf(1_000_000L)).longValueExact()
  }
  ```

---

## 3. التكلفة المرجحة (MAC) على مستوى المستودع والتكلفة التاريخية

### 3.1 معادلة MAC الموحدة لكل مستودع
تخزن التكلفة في `inventory_balances.current_moving_avg_cost` على مستوى `(warehouse_id, stock_item_id)`:
$$\text{NewMAC} = \left\lfloor \frac{(\text{OldQuantity} \times \text{OldMAC}) + (\text{ReceivedQuantity} \times \text{EffectiveUnitCost}) + \lfloor \frac{\text{TotalQuantity}}{2} \rfloor}{\text{TotalQuantity}} \right\rfloor$$
- إذا كان $\text{OldQuantity} = 0$، فإن $\text{NewMAC} = \text{EffectiveUnitCost}$.
- إذا كانت الكمية موجبة لكن $\text{OldMAC} = 0$، يتم اعتماد تكلفة الاستلام الجديد كقيمة مصححة للـ MAC.

### 3.2 المعالجة المحاسبية لحالات الحركة
1. **الاستلامات (كاملة، جزئية، متعددة):** كل استلام شراء في `purchase_receipt_items` يرفع `OnHand` ويحدث `current_moving_avg_cost` فورياً بالكمية وتكلفتها شاملة أي مصاريف إضافية مخصصة.
2. **مرتجع مبيعات:** يدخل الصنف بالتكلفة التاريخية المسجلة في `sale_items.unit_cost_snapshot` وقت البيع، ويعاد احتساب MAC للمستودع لحماية الأرباح.
3. **مرتجع مورد:**
   - يخرج المخزون بـ **MAC الحالي للمستودع**.
   - قيمة مطالبة المورد تعتمد على **سعر الشراء الأصلي**.
   - الفارق المحاسبي: يسجل في حساب تسوية تسعير الموردين (`Cost Variance Adjustment`) دون تعديل تكلفة الفواتير القديمة.
4. **التلف والفقد وعجز الجرد:** يخرج المخزون بـ **MAC الحالي** مع **بقاء قيمة MAC للوحدة دون أي تغيير**.
5. **فائض الجرد:** يدخل الصنف بـ MAC الحالي، وفي حال عدم وجود MAC يطلب النظام إدخال تكلفة تقديرية معتمدة ولا يقبل صفراً بصمت.
6. **ثبات التكلفة التاريخية:** لا يؤدي تغير MAC المستقبلي إلى تعديل تكلفة المبيعات في الفواتير المعتمدة السابقة إطلاقاً (`sale_items.unit_cost_snapshot` مجمدة).

---

## 4. نموذج المخزون، الحصص (Offline Quotas)، ودورة التسوية

### 4.1 معادلة الأرصدة ودورة الحصة
$$\text{Available} = \text{OnHand} - \text{Reserved}$$
- **عند حجز حصة (كمية $Q$):**
  $\text{Reserved} = \text{Reserved} + Q$. (لا تتغير $\text{OnHand}$؛ وتصبح $\text{Available}$ أقل بمقدار $Q$).
- **أثناء البيع دون اتصال (Android Offline):**
  يستهلك الجهاز محلياً فقط في حدود $Q$. لا يتغير أي رصيد في الخادم المركزي.
- **عند التسوية المركزية لحصة مقدارها $Q$ واستهلاكها الفعلي $C$ (والمتبقي $R = Q - C$):**
  تنفذ معاملة ذرية واحدة على الخادم:
  $$\text{OnHand}_{\text{new}} = \text{OnHand}_{\text{old}} - C$$
  $$\text{Reserved}_{\text{new}} = \text{Reserved}_{\text{old}} - Q$$
  ينتج عن ذلك:
  $$\text{Available}_{\text{new}} = \text{OnHand}_{\text{new}} - \text{Reserved}_{\text{new}} = (\text{OnHand}_{\text{old}} - C) - (\text{Reserved}_{\text{old}} - Q) = \text{Available}_{\text{old}} + (Q - C)$$
  أي أن الكمية غير المستهلكة $(Q - C)$ تتحرر فورياً لتصبح متاحة في المركز، وتخصم الكمية المباعة $C$ من الوجود الفعلي دون أي خصم مزدوج.

### 4.2 الربط الصريح عبر `sale_item_quota_allocations`
كل سطر بيع ينفذ أثناء انقطاع الاتصال يخصص له سجل يحدد:
- `sale_item_id`
- `quota_id`
- `allocated_quantity`
- وتتحقق المعاملة المركزية من تطابق `stock_item_id` و `warehouse_id` و `device_id`، وأن مجموع استهلاك الحصة عبر السطور $\le \text{AllocatedQuantity}$.

### 4.3 سياسة فقدان الجهاز وإلغاء الحصة (Force Void Quota)
- لا يعتبر كامل الحصة عجزاً تلقائياً.
- يفصل النظام بين:
  1. مبيعات الحصة التي سبق رفعها (مباع معتمد).
  2. المتبقي غير المسوى (مجهول المصير).
- يتطلب إجراء `Force Void Quota` قراراً إدارياً موثقاً من المدير يحدد ما إذا كانت الكمية المتبقية تعتبر عجزاً مخزنياً موثقاً في `inventory_movements` بنوع `LOSS`، أم يعاد إدراجها للمتاح بعد جرد المستودع، مع قيد تدقيق كامل في `audit_logs`.
- **حدود الثقة:** إبطال الجهاز في المضيف لا يوقف الجهاز المفقود فوراً إذا كان غير متصل؛ لذا يضمن النظام أن أقصى خطر مالي محتمل معزول في حدود الكمية المتبقية من الحصة الممنوحة فقط.

---

## 5. أمن الأجهزة والعمليات ومقاومة Replay

- **المفاتيح والتوقيع:**
  - المضيف: يوقع الحصص بـ `host_ed25519_private_key`.
  - الأجهزة: يولد كل جهاز مفتاح Ed25519 في `Android Keystore` (أو التخزين المشفر للمنصة) ويرسل المفتاح العام أثناء الاقتران.
- **التوقيع المعياري لحزمة المبيعات:**
  يتم تشفير السلسلة القياسية الحتمية (Deterministic Canonical String) لجميع بنود الفاتورة:
  `V1|device_id|local_op_uuid|seq_num|warehouse_id|total_amount|items_sha256|quotas_sha256`
- **قيود مقاومة التكرار:**
  - قيد فريد: `UNIQUE (device_id, device_sequence_number)`.
  - قيد فريد: `UNIQUE (device_id, idempotency_key)`.
  - يتحقق المضيف من أن `device_sequence_number > last_operation_sequence`. أي عملية مكررة أو تراجعية ترفض فوراً.
- **حدود حماية Keystore:** التوقيع الرقمي يحمي حزمة المبيعات أثناء النقل ويمنع انتحال صفة الجهاز، لكنه لا يمنع التلاعب المادي بالجهاز إذا تم كسر حمايته (Rooted). لذا فإن تحديد سقف كمية وتاريخ الحصة هو صمام الأمان الفعلي.

---

## 6. ترقيم الفواتير ومطابقة السجلات

- **النموذج B المعتمد:**
  1. أثناء انقطاع الاتصال: يصدر الجهاز رقماً محلياً فريداً يطبع على إيصال العميل:
     `REC-DEV01-2026-00042` (مسجل في `offline_receipt_number`).
  2. عند التسوية بالمضيف: يخصص المضيف رقماً رسمياً تسلسلياً غير قابل للتكرار:
     `INV-2026-0001589` (مسجل في `invoice_number`).
  3. الفواتير الملغاة تحتفظ برقمها الرسمي وحالتها `CANCELLED` في السجل ولا تحذف، لمنع الشبهات المالية وإثبات تسلسل الأرقام ضريبياً.

---

## 7. الدفعات والدفتر المالي والصناديق النقدية

- **`payment_allocations`:** قيد XOR صارم يمنع أن يرتبط التخصيص بـ `sale_id` و `purchase_id` معاً أو بفراغهما معاً.
- **`financial_ledger`:** هو **دفتر ذمم وحسابات أطراف (Party Account Ledger)** وليس نظام محاسبة عامة مزدوج (General Ledger). إشارات العمليات:
  - فاتورة بيع لعميل: $+ \text{Amount}$ (دين لنا).
  - دفعة مسددة من عميل: $- \text{Amount}$ (تخفيض دين).
  - فاتورة شراء من مورد: $- \text{Amount}$ (دين علينا للمورد).
  - سداد لمورد: $+ \text{Amount}$ (تخفيض دين المورد).
  - كل حركة تحمل `source_event_id TEXT UNIQUE` لمنع تكرار الترحيل المالي.
- **`cash_movements`:** تسجل كل تدفق نقدي حقيقي داخل `cash_sessions`، مع قيد فريد يمنع فتح أكثر من وردية نشطة واحدة لنفس الجهاز في الوقت ذاته (`idx_single_open_cash_session`).

---

## 8. مخطط قاعدة البيانات الكامل بعد التصحيح (Verified 42 Tables SQL DDL)

**تم تنفيذ هذا المخطط واختباره فعلياً على محرك SQLite 3.40.1، ونتج عنه 42 جدولاً بالضبط، مع نجاح كامل لفحص القيود `PRAGMA foreign_key_check` بـ 0 أخطاء:**

```sql
PRAGMA journal_mode = WAL;
PRAGMA foreign_keys = ON;

-- 1. المتجر والمستودعات
CREATE TABLE stores (
    id TEXT PRIMARY KEY NOT NULL,
    name TEXT NOT NULL,
    trade_name TEXT,
    tax_number TEXT,
    phone TEXT,
    address TEXT,
    currency_code TEXT NOT NULL DEFAULT 'DZD',
    currency_symbol TEXT NOT NULL DEFAULT 'دج',
    currency_scale INTEGER NOT NULL DEFAULT 2,
    price_includes_tax INTEGER NOT NULL DEFAULT 0,
    default_tax_rate INTEGER NOT NULL DEFAULT 0,
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL
);

CREATE TABLE warehouses (
    id TEXT PRIMARY KEY NOT NULL,
    store_id TEXT NOT NULL,
    name TEXT NOT NULL,
    code TEXT UNIQUE NOT NULL,
    is_default INTEGER NOT NULL DEFAULT 0,
    is_active INTEGER NOT NULL DEFAULT 1,
    created_at INTEGER NOT NULL,
    FOREIGN KEY (store_id) REFERENCES stores(id) ON DELETE RESTRICT
);
CREATE UNIQUE INDEX idx_single_default_warehouse ON warehouses(store_id) WHERE is_default = 1;

-- 2. المستخدمون والصلاحيات والجلسات
CREATE TABLE users (
    id TEXT PRIMARY KEY NOT NULL,
    username TEXT UNIQUE NOT NULL,
    password_hash TEXT NOT NULL,
    password_salt TEXT NOT NULL,
    full_name TEXT NOT NULL,
    role TEXT NOT NULL,
    is_active INTEGER NOT NULL DEFAULT 1,
    created_at INTEGER NOT NULL
);

CREATE TABLE user_permissions (
    user_id TEXT NOT NULL,
    permission TEXT NOT NULL,
    PRIMARY KEY (user_id, permission),
    FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
);

CREATE TABLE user_sessions (
    id TEXT PRIMARY KEY NOT NULL,
    user_id TEXT NOT NULL,
    device_id TEXT NOT NULL,
    token_hash TEXT UNIQUE NOT NULL,
    issued_at INTEGER NOT NULL,
    expires_at INTEGER NOT NULL,
    is_revoked INTEGER NOT NULL DEFAULT 0,
    FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE RESTRICT
);

-- 3. الأجهزة والاقتران ومنع التكرار
CREATE TABLE registered_devices (
    id TEXT PRIMARY KEY NOT NULL,
    device_name TEXT NOT NULL,
    platform TEXT NOT NULL,
    device_public_key TEXT NOT NULL,
    paired_at INTEGER NOT NULL,
    last_seen_at INTEGER NOT NULL,
    last_operation_sequence INTEGER NOT NULL DEFAULT 0,
    is_revoked INTEGER NOT NULL DEFAULT 0,
    revoked_at INTEGER
);

CREATE TABLE device_pairing_pins (
    pin_hash TEXT PRIMARY KEY NOT NULL,
    created_at INTEGER NOT NULL,
    expires_at INTEGER NOT NULL,
    attempts_remaining INTEGER NOT NULL DEFAULT 3,
    is_used INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE idempotent_requests (
    device_id TEXT NOT NULL,
    idempotency_key TEXT NOT NULL,
    operation_type TEXT NOT NULL,
    request_hash TEXT NOT NULL,
    status TEXT NOT NULL,
    response_code INTEGER,
    response_body TEXT,
    created_at INTEGER NOT NULL,
    PRIMARY KEY (device_id, idempotency_key),
    FOREIGN KEY (device_id) REFERENCES registered_devices(id) ON DELETE RESTRICT
);
CREATE INDEX idx_idempotent_created ON idempotent_requests(created_at);

-- 4. وحدات القياس والتحويلات والكتالوج
CREATE TABLE units_of_measure (
    id TEXT PRIMARY KEY NOT NULL,
    dimension TEXT NOT NULL, -- COUNT, WEIGHT, VOLUME, LENGTH
    name_ar TEXT NOT NULL,
    name_fr TEXT,
    symbol TEXT NOT NULL,
    is_fractional INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE unit_conversions (
    id TEXT PRIMARY KEY NOT NULL,
    from_unit_id TEXT NOT NULL,
    to_unit_id TEXT NOT NULL,
    factor_numerator INTEGER NOT NULL,
    factor_denominator INTEGER NOT NULL,
    UNIQUE (from_unit_id, to_unit_id),
    FOREIGN KEY (from_unit_id) REFERENCES units_of_measure(id) ON DELETE RESTRICT,
    FOREIGN KEY (to_unit_id) REFERENCES units_of_measure(id) ON DELETE RESTRICT,
    CHECK (factor_numerator > 0),
    CHECK (factor_denominator > 0)
);

CREATE TABLE categories (
    id TEXT PRIMARY KEY NOT NULL,
    parent_id TEXT,
    name_ar TEXT NOT NULL,
    name_fr TEXT,
    created_at INTEGER NOT NULL,
    FOREIGN KEY (parent_id) REFERENCES categories(id) ON DELETE SET NULL
);

CREATE TABLE products (
    id TEXT PRIMARY KEY NOT NULL,
    category_id TEXT,
    base_unit_id TEXT NOT NULL DEFAULT 'UOM_PIECE',
    name TEXT NOT NULL,
    description TEXT,
    internal_code TEXT UNIQUE,
    track_inventory INTEGER NOT NULL DEFAULT 1,
    has_variants INTEGER NOT NULL DEFAULT 0,
    is_active INTEGER NOT NULL DEFAULT 1,
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL,
    FOREIGN KEY (category_id) REFERENCES categories(id) ON DELETE SET NULL,
    FOREIGN KEY (base_unit_id) REFERENCES units_of_measure(id) ON DELETE RESTRICT
);

CREATE TABLE stock_items (
    id TEXT PRIMARY KEY NOT NULL,
    product_id TEXT NOT NULL,
    variant_name TEXT,
    sku TEXT UNIQUE,
    barcode TEXT UNIQUE,
    default_sale_price INTEGER,
    min_stock_alert INTEGER NOT NULL DEFAULT 0,
    is_active INTEGER NOT NULL DEFAULT 1,
    created_at INTEGER NOT NULL,
    FOREIGN KEY (product_id) REFERENCES products(id) ON DELETE RESTRICT
);

CREATE TABLE attribute_definitions (
    id TEXT PRIMARY KEY NOT NULL,
    name_ar TEXT NOT NULL,
    name_fr TEXT,
    attribute_type TEXT NOT NULL
);

CREATE TABLE stock_item_attributes (
    stock_item_id TEXT NOT NULL,
    attribute_id TEXT NOT NULL,
    attribute_value TEXT NOT NULL,
    PRIMARY KEY (stock_item_id, attribute_id),
    FOREIGN KEY (stock_item_id) REFERENCES stock_items(id) ON DELETE RESTRICT,
    FOREIGN KEY (attribute_id) REFERENCES attribute_definitions(id) ON DELETE RESTRICT
);

-- 5. الأرصدة ودفتر المخزون وحصص Offline
CREATE TABLE inventory_balances (
    warehouse_id TEXT NOT NULL,
    stock_item_id TEXT NOT NULL,
    on_hand_quantity INTEGER NOT NULL DEFAULT 0,
    reserved_quantity INTEGER NOT NULL DEFAULT 0,
    current_moving_avg_cost INTEGER NOT NULL DEFAULT 0,
    updated_at INTEGER NOT NULL,
    PRIMARY KEY (warehouse_id, stock_item_id),
    FOREIGN KEY (warehouse_id) REFERENCES warehouses(id) ON DELETE RESTRICT,
    FOREIGN KEY (stock_item_id) REFERENCES stock_items(id) ON DELETE RESTRICT,
    CHECK (on_hand_quantity >= 0),
    CHECK (reserved_quantity >= 0),
    CHECK (on_hand_quantity >= reserved_quantity),
    CHECK (current_moving_avg_cost >= 0)
);

CREATE TABLE inventory_movements (
    id TEXT PRIMARY KEY NOT NULL,
    warehouse_id TEXT NOT NULL,
    stock_item_id TEXT NOT NULL,
    movement_type TEXT NOT NULL,
    quantity INTEGER NOT NULL,
    unit_cost INTEGER NOT NULL,
    balance_after INTEGER NOT NULL,
    reference_document_type TEXT NOT NULL,
    reference_document_id TEXT NOT NULL,
    notes TEXT,
    created_by_user_id TEXT NOT NULL,
    created_at INTEGER NOT NULL,
    FOREIGN KEY (warehouse_id) REFERENCES warehouses(id) ON DELETE RESTRICT,
    FOREIGN KEY (stock_item_id) REFERENCES stock_items(id) ON DELETE RESTRICT,
    FOREIGN KEY (created_by_user_id) REFERENCES users(id) ON DELETE RESTRICT,
    CHECK (quantity > 0),
    CHECK (unit_cost >= 0)
);
CREATE INDEX idx_movements_item ON inventory_movements(stock_item_id, created_at);

CREATE TABLE inventory_quotas (
    id TEXT PRIMARY KEY NOT NULL,
    device_id TEXT NOT NULL,
    warehouse_id TEXT NOT NULL,
    stock_item_id TEXT NOT NULL,
    allocated_quantity INTEGER NOT NULL,
    consumed_quantity INTEGER NOT NULL DEFAULT 0,
    status TEXT NOT NULL,
    valid_until INTEGER NOT NULL,
    issued_at INTEGER NOT NULL,
    reconciled_at INTEGER,
    nonce TEXT UNIQUE NOT NULL,
    host_ed25519_signature TEXT NOT NULL,
    FOREIGN KEY (device_id) REFERENCES registered_devices(id) ON DELETE RESTRICT,
    FOREIGN KEY (warehouse_id) REFERENCES warehouses(id) ON DELETE RESTRICT,
    FOREIGN KEY (stock_item_id) REFERENCES stock_items(id) ON DELETE RESTRICT,
    CHECK (allocated_quantity > 0),
    CHECK (consumed_quantity >= 0),
    CHECK (allocated_quantity >= consumed_quantity),
    CHECK (status IN ('ACTIVE', 'EXPIRED', 'RECONCILED', 'VOIDED_BY_ADMIN'))
);

-- 6. الأطراف ودفتر الحسابات المالية (Party Account Ledger)
CREATE TABLE parties (
    id TEXT PRIMARY KEY NOT NULL,
    type TEXT NOT NULL,
    name TEXT NOT NULL,
    phone TEXT,
    email TEXT,
    tax_number TEXT,
    current_balance INTEGER NOT NULL DEFAULT 0,
    is_active INTEGER NOT NULL DEFAULT 1,
    created_at INTEGER NOT NULL,
    CHECK (type IN ('CUSTOMER', 'SUPPLIER'))
);

CREATE TABLE financial_ledger (
    id TEXT PRIMARY KEY NOT NULL,
    party_id TEXT NOT NULL,
    entry_type TEXT NOT NULL,
    amount INTEGER NOT NULL,
    balance_after INTEGER NOT NULL,
    reference_document_type TEXT NOT NULL,
    reference_document_id TEXT NOT NULL,
    source_event_id TEXT UNIQUE NOT NULL,
    notes TEXT,
    created_by_user_id TEXT NOT NULL,
    created_at INTEGER NOT NULL,
    FOREIGN KEY (party_id) REFERENCES parties(id) ON DELETE RESTRICT,
    FOREIGN KEY (created_by_user_id) REFERENCES users(id) ON DELETE RESTRICT,
    CHECK (amount > 0)
);
CREATE INDEX idx_financial_party ON financial_ledger(party_id, created_at);

CREATE TABLE document_sequences (
    sequence_type TEXT PRIMARY KEY NOT NULL,
    current_number INTEGER NOT NULL DEFAULT 0
);

-- 7. المبيعات وبنودها وتخصيص الحصص والمرتجعات
CREATE TABLE sales (
    id TEXT PRIMARY KEY NOT NULL,
    invoice_number TEXT UNIQUE,
    offline_receipt_number TEXT UNIQUE,
    warehouse_id TEXT NOT NULL,
    customer_id TEXT,
    created_by_user_id TEXT NOT NULL,
    device_id TEXT NOT NULL,
    device_sequence_number INTEGER,
    device_signature TEXT,
    subtotal_amount INTEGER NOT NULL,
    discount_amount INTEGER NOT NULL DEFAULT 0,
    tax_amount INTEGER NOT NULL DEFAULT 0,
    total_amount INTEGER NOT NULL,
    paid_amount INTEGER NOT NULL,
    remaining_debt INTEGER NOT NULL,
    status TEXT NOT NULL,
    created_at INTEGER NOT NULL,
    reconciled_at INTEGER,
    FOREIGN KEY (warehouse_id) REFERENCES warehouses(id) ON DELETE RESTRICT,
    FOREIGN KEY (customer_id) REFERENCES parties(id) ON DELETE RESTRICT,
    FOREIGN KEY (created_by_user_id) REFERENCES users(id) ON DELETE RESTRICT,
    FOREIGN KEY (device_id) REFERENCES registered_devices(id) ON DELETE RESTRICT,
    CHECK (total_amount >= 0),
    CHECK (paid_amount >= 0),
    CHECK (remaining_debt >= 0),
    CHECK (total_amount = paid_amount + remaining_debt),
    CHECK (status IN ('COMPLETED', 'CANCELLED', 'REFUNDED_PARTIAL', 'REFUNDED_FULL', 'PENDING_RECONCILIATION'))
);
CREATE UNIQUE INDEX idx_sales_device_seq ON sales(device_id, device_sequence_number) WHERE device_sequence_number IS NOT NULL;

CREATE TABLE sale_items (
    id TEXT PRIMARY KEY NOT NULL,
    sale_id TEXT NOT NULL,
    stock_item_id TEXT NOT NULL,
    item_name_snapshot TEXT NOT NULL,
    quantity INTEGER NOT NULL,
    unit_price INTEGER NOT NULL,
    unit_cost_snapshot INTEGER NOT NULL,
    discount_rate INTEGER NOT NULL DEFAULT 0,
    tax_rate INTEGER NOT NULL DEFAULT 0,
    line_subtotal INTEGER NOT NULL,
    line_discount INTEGER NOT NULL,
    line_tax INTEGER NOT NULL,
    total_line_amount INTEGER NOT NULL,
    FOREIGN KEY (sale_id) REFERENCES sales(id) ON DELETE RESTRICT,
    FOREIGN KEY (stock_item_id) REFERENCES stock_items(id) ON DELETE RESTRICT,
    CHECK (quantity > 0),
    CHECK (unit_price >= 0),
    CHECK (total_line_amount >= 0)
);

CREATE TABLE sale_item_quota_allocations (
    id TEXT PRIMARY KEY NOT NULL,
    sale_item_id TEXT NOT NULL,
    quota_id TEXT NOT NULL,
    allocated_quantity INTEGER NOT NULL,
    FOREIGN KEY (sale_item_id) REFERENCES sale_items(id) ON DELETE RESTRICT,
    FOREIGN KEY (quota_id) REFERENCES inventory_quotas(id) ON DELETE RESTRICT,
    CHECK (allocated_quantity > 0)
);

CREATE TABLE sale_returns (
    id TEXT PRIMARY KEY NOT NULL,
    return_number TEXT UNIQUE NOT NULL,
    original_sale_id TEXT NOT NULL,
    created_by_user_id TEXT NOT NULL,
    device_id TEXT NOT NULL,
    refund_amount INTEGER NOT NULL,
    refund_method TEXT NOT NULL,
    reason TEXT,
    created_at INTEGER NOT NULL,
    FOREIGN KEY (original_sale_id) REFERENCES sales(id) ON DELETE RESTRICT,
    FOREIGN KEY (created_by_user_id) REFERENCES users(id) ON DELETE RESTRICT,
    FOREIGN KEY (device_id) REFERENCES registered_devices(id) ON DELETE RESTRICT,
    CHECK (refund_amount > 0),
    CHECK (refund_method IN ('CASH', 'STORE_CREDIT', 'DEBT_REDUCTION'))
);

CREATE TABLE sale_return_items (
    id TEXT PRIMARY KEY NOT NULL,
    sale_return_id TEXT NOT NULL,
    original_sale_item_id TEXT NOT NULL,
    stock_item_id TEXT NOT NULL,
    returned_quantity INTEGER NOT NULL,
    item_condition TEXT NOT NULL DEFAULT 'RESALEABLE',
    refund_unit_price INTEGER NOT NULL,
    historical_unit_cost INTEGER NOT NULL,
    total_refund_line INTEGER NOT NULL,
    FOREIGN KEY (sale_return_id) REFERENCES sale_returns(id) ON DELETE RESTRICT,
    FOREIGN KEY (original_sale_item_id) REFERENCES sale_items(id) ON DELETE RESTRICT,
    FOREIGN KEY (stock_item_id) REFERENCES stock_items(id) ON DELETE RESTRICT,
    CHECK (returned_quantity > 0),
    CHECK (total_refund_line > 0),
    CHECK (item_condition IN ('RESALEABLE', 'DAMAGED', 'QUARANTINE'))
);

-- 8. المشتريات والاستلام ومرتجعات الموردين
CREATE TABLE purchases (
    id TEXT PRIMARY KEY NOT NULL,
    order_number TEXT UNIQUE NOT NULL,
    supplier_id TEXT NOT NULL,
    warehouse_id TEXT NOT NULL,
    created_by_user_id TEXT NOT NULL,
    total_amount INTEGER NOT NULL,
    paid_amount INTEGER NOT NULL,
    remaining_debt INTEGER NOT NULL,
    status TEXT NOT NULL,
    created_at INTEGER NOT NULL,
    FOREIGN KEY (supplier_id) REFERENCES parties(id) ON DELETE RESTRICT,
    FOREIGN KEY (warehouse_id) REFERENCES warehouses(id) ON DELETE RESTRICT,
    FOREIGN KEY (created_by_user_id) REFERENCES users(id) ON DELETE RESTRICT,
    CHECK (total_amount >= 0),
    CHECK (status IN ('DRAFT', 'PARTIALLY_RECEIVED', 'FULLY_RECEIVED', 'CANCELLED'))
);

CREATE TABLE purchase_items (
    id TEXT PRIMARY KEY NOT NULL,
    purchase_id TEXT NOT NULL,
    stock_item_id TEXT NOT NULL,
    ordered_quantity INTEGER NOT NULL,
    received_quantity INTEGER NOT NULL DEFAULT 0,
    unit_cost INTEGER NOT NULL,
    total_line_amount INTEGER NOT NULL,
    FOREIGN KEY (purchase_id) REFERENCES purchases(id) ON DELETE RESTRICT,
    FOREIGN KEY (stock_item_id) REFERENCES stock_items(id) ON DELETE RESTRICT,
    CHECK (ordered_quantity > 0),
    CHECK (received_quantity >= 0),
    CHECK (received_quantity <= ordered_quantity)
);

CREATE TABLE purchase_receipts (
    id TEXT PRIMARY KEY NOT NULL,
    receipt_number TEXT UNIQUE NOT NULL,
    purchase_id TEXT NOT NULL,
    warehouse_id TEXT NOT NULL,
    created_by_user_id TEXT NOT NULL,
    received_at INTEGER NOT NULL,
    FOREIGN KEY (purchase_id) REFERENCES purchases(id) ON DELETE RESTRICT,
    FOREIGN KEY (warehouse_id) REFERENCES warehouses(id) ON DELETE RESTRICT,
    FOREIGN KEY (created_by_user_id) REFERENCES users(id) ON DELETE RESTRICT
);

CREATE TABLE purchase_receipt_items (
    id TEXT PRIMARY KEY NOT NULL,
    receipt_id TEXT NOT NULL,
    purchase_item_id TEXT NOT NULL,
    stock_item_id TEXT NOT NULL,
    quantity_received INTEGER NOT NULL,
    unit_cost INTEGER NOT NULL,
    FOREIGN KEY (receipt_id) REFERENCES purchase_receipts(id) ON DELETE RESTRICT,
    FOREIGN KEY (purchase_item_id) REFERENCES purchase_items(id) ON DELETE RESTRICT,
    FOREIGN KEY (stock_item_id) REFERENCES stock_items(id) ON DELETE RESTRICT,
    CHECK (quantity_received > 0)
);

CREATE TABLE supplier_returns (
    id TEXT PRIMARY KEY NOT NULL,
    return_number TEXT UNIQUE NOT NULL,
    supplier_id TEXT NOT NULL,
    warehouse_id TEXT NOT NULL,
    reference_receipt_id TEXT,
    created_by_user_id TEXT NOT NULL,
    total_refund_amount INTEGER NOT NULL,
    status TEXT NOT NULL,
    created_at INTEGER NOT NULL,
    FOREIGN KEY (supplier_id) REFERENCES parties(id) ON DELETE RESTRICT,
    FOREIGN KEY (warehouse_id) REFERENCES warehouses(id) ON DELETE RESTRICT,
    FOREIGN KEY (reference_receipt_id) REFERENCES purchase_receipts(id) ON DELETE RESTRICT,
    FOREIGN KEY (created_by_user_id) REFERENCES users(id) ON DELETE RESTRICT,
    CHECK (total_refund_amount > 0)
);

CREATE TABLE supplier_return_items (
    id TEXT PRIMARY KEY NOT NULL,
    supplier_return_id TEXT NOT NULL,
    purchase_receipt_item_id TEXT,
    stock_item_id TEXT NOT NULL,
    quantity INTEGER NOT NULL,
    unit_cost INTEGER NOT NULL,
    total_line_amount INTEGER NOT NULL,
    FOREIGN KEY (supplier_return_id) REFERENCES supplier_returns(id) ON DELETE RESTRICT,
    FOREIGN KEY (purchase_receipt_item_id) REFERENCES purchase_receipt_items(id) ON DELETE RESTRICT,
    FOREIGN KEY (stock_item_id) REFERENCES stock_items(id) ON DELETE RESTRICT,
    CHECK (quantity > 0)
);

-- 9. الدفعات وتخصيصها
CREATE TABLE payments (
    id TEXT PRIMARY KEY NOT NULL,
    payment_number TEXT UNIQUE NOT NULL,
    party_id TEXT NOT NULL,
    amount INTEGER NOT NULL,
    payment_method TEXT NOT NULL,
    reference_note TEXT,
    created_by_user_id TEXT NOT NULL,
    created_at INTEGER NOT NULL,
    FOREIGN KEY (party_id) REFERENCES parties(id) ON DELETE RESTRICT,
    FOREIGN KEY (created_by_user_id) REFERENCES users(id) ON DELETE RESTRICT,
    CHECK (amount > 0),
    CHECK (payment_method IN ('CASH', 'BANK_TRANSFER', 'CHECK'))
);

CREATE TABLE payment_allocations (
    id TEXT PRIMARY KEY NOT NULL,
    payment_id TEXT NOT NULL,
    sale_id TEXT,
    purchase_id TEXT,
    allocated_amount INTEGER NOT NULL,
    FOREIGN KEY (payment_id) REFERENCES payments(id) ON DELETE RESTRICT,
    FOREIGN KEY (sale_id) REFERENCES sales(id) ON DELETE RESTRICT,
    FOREIGN KEY (purchase_id) REFERENCES purchases(id) ON DELETE RESTRICT,
    CHECK (allocated_amount > 0),
    CHECK (
        (sale_id IS NOT NULL AND purchase_id IS NULL) OR
        (sale_id IS NULL AND purchase_id IS NOT NULL)
    )
);

-- 10. الجرد والتسويات
CREATE TABLE stock_audits (
    id TEXT PRIMARY KEY NOT NULL,
    audit_number TEXT UNIQUE NOT NULL,
    warehouse_id TEXT NOT NULL,
    status TEXT NOT NULL,
    started_at INTEGER NOT NULL,
    completed_at INTEGER,
    created_by_user_id TEXT NOT NULL,
    FOREIGN KEY (warehouse_id) REFERENCES warehouses(id) ON DELETE RESTRICT,
    FOREIGN KEY (created_by_user_id) REFERENCES users(id) ON DELETE RESTRICT,
    CHECK (status IN ('IN_PROGRESS', 'COMPLETED', 'CANCELLED'))
);

CREATE TABLE stock_audit_items (
    id TEXT PRIMARY KEY NOT NULL,
    audit_id TEXT NOT NULL,
    stock_item_id TEXT NOT NULL,
    system_quantity INTEGER NOT NULL,
    counted_quantity INTEGER NOT NULL,
    difference_quantity INTEGER NOT NULL,
    unit_cost_snapshot INTEGER NOT NULL,
    FOREIGN KEY (audit_id) REFERENCES stock_audits(id) ON DELETE RESTRICT,
    FOREIGN KEY (stock_item_id) REFERENCES stock_items(id) ON DELETE RESTRICT
);

-- 11. الصناديق وحركات النقدية والمصروفات والتدقيق والترخيص
CREATE TABLE cash_sessions (
    id TEXT PRIMARY KEY NOT NULL,
    user_id TEXT NOT NULL,
    device_id TEXT NOT NULL,
    opened_at INTEGER NOT NULL,
    closed_at INTEGER,
    opening_balance INTEGER NOT NULL,
    expected_closing_balance INTEGER,
    actual_closing_balance INTEGER,
    discrepancy_amount INTEGER,
    status TEXT NOT NULL DEFAULT 'OPEN',
    FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE RESTRICT,
    FOREIGN KEY (device_id) REFERENCES registered_devices(id) ON DELETE RESTRICT,
    CHECK (opening_balance >= 0),
    CHECK (status IN ('OPEN', 'CLOSED'))
);
CREATE UNIQUE INDEX idx_single_open_cash_session ON cash_sessions(device_id) WHERE status = 'OPEN';

CREATE TABLE cash_movements (
    id TEXT PRIMARY KEY NOT NULL,
    cash_session_id TEXT NOT NULL,
    movement_type TEXT NOT NULL,
    amount INTEGER NOT NULL,
    reference_document_type TEXT,
    reference_document_id TEXT,
    source_event_id TEXT UNIQUE NOT NULL,
    notes TEXT,
    created_at INTEGER NOT NULL,
    FOREIGN KEY (cash_session_id) REFERENCES cash_sessions(id) ON DELETE RESTRICT,
    CHECK (amount > 0),
    CHECK (movement_type IN ('SALE_CASH_IN', 'DEBT_COLLECTION_IN', 'EXPENSE_OUT', 'REFUND_CASH_OUT', 'CASH_DROP_OUT'))
);
CREATE INDEX idx_cash_movements_session ON cash_movements(cash_session_id);

CREATE TABLE expenses (
    id TEXT PRIMARY KEY NOT NULL,
    cash_session_id TEXT,
    category TEXT NOT NULL,
    amount INTEGER NOT NULL,
    description TEXT,
    created_by_user_id TEXT NOT NULL,
    created_at INTEGER NOT NULL,
    FOREIGN KEY (cash_session_id) REFERENCES cash_sessions(id) ON DELETE RESTRICT,
    FOREIGN KEY (created_by_user_id) REFERENCES users(id) ON DELETE RESTRICT,
    CHECK (amount > 0)
);

CREATE TABLE audit_logs (
    id TEXT PRIMARY KEY NOT NULL,
    user_id TEXT,
    device_id TEXT,
    user_name_snapshot TEXT NOT NULL,
    device_name_snapshot TEXT NOT NULL,
    action TEXT NOT NULL,
    entity_name TEXT NOT NULL,
    entity_id TEXT NOT NULL,
    details_json TEXT,
    timestamp INTEGER NOT NULL
);

CREATE TABLE system_license (
    store_id TEXT PRIMARY KEY NOT NULL,
    license_key TEXT NOT NULL,
    license_type TEXT NOT NULL,
    max_devices INTEGER NOT NULL DEFAULT 5,
    issued_date INTEGER NOT NULL,
    expiry_date INTEGER,
    features_json TEXT,
    ed25519_signature TEXT NOT NULL,
    last_verified_at INTEGER NOT NULL
);

CREATE TABLE backup_history (
    id TEXT PRIMARY KEY NOT NULL,
    backup_path TEXT NOT NULL,
    file_size_bytes INTEGER NOT NULL,
    sha256_checksum TEXT NOT NULL,
    is_encrypted INTEGER NOT NULL DEFAULT 1,
    created_at INTEGER NOT NULL,
    verified_at INTEGER
);
```

---

## 9. مصفوفة اختبارات إثبات التقنية الموسعة (PoT - 20 اختباراً) وحدود المسؤولية

### فصل المسؤولية الصريح بين PoT والوحدة الثانية:
- **الوحدة صفر (PoT):** تستخدم المخطط النهائي الكامل أعلاه كـ **Reference DDL Fixture** في قاعدة اختبارية محلية للتحقق العملي من بناء البيئتين، تشغيل برامج التشغيل (JDBC / Android)، اتصال Ktor المشفر بـ TLS، التزامن الشرطي بطلبين متزامنين لآخر قطعة، ومحاكاة توقيع العمليات.
- **الوحدة الثانية (Production Schema & Repositories):** تقوم بدمج ملفات SQLDelight المنظمة وتوليد الـ DAOs وكتابة الـ Repositories وربطها بحالات الاستخدام الفعلية.

| # | اسم الاختبار | بيئة التنفيذ | المدخلات والخطوات | النتيجة المتوقعة والمعيار |
| :---: | :--- | :--- | :--- | :--- |
| **1** | Windows Clean Build | Windows Desktop (JVM) | تجميع مشروع KMP على الديسكتوب. | بناء ناجح دون أي أخطاء ترجمة. |
| **2** | Android Clean Build | Android Runtime (API 24+) | تجميع مشروع أندرويد. | بناء وتثبيت ناجح للـ APK. |
| **3** | Shared Domain Run | KMP Common | تنفيذ اختبارات العمليات الحسابية بدون منصة. | تطابق المتجه المرجعي (38,861 سنتيم). |
| **4** | SQLDelight Drivers | JVM & Android | فتح SQLite بـ JDBC و AndroidSqliteDriver. | فتح قاعدة البيانات بنجاح في البيئتين. |
| **5** | Schema DDL & FK Check | SQLite 3.40+ | تنفيذ الـ DDL وتشغيل `PRAGMA foreign_key_check`. | إنشاء 42 جدولاً و 0 أخطاء في الـ FKs. |
| **6** | Ktor Local TLS & Pinning | LAN Network | خادم Ktor مع شهادة ذاتية وعميل أندرويد. | اتصال HTTPS آمن ونجاح Handshake. |
| **7** | Concurrent Sale Race | Multi-threaded | طلبان متزامنان لبيع آخر قطعة متوفرة. | اعتماد طلب واحد برمز 200 ورفض الآخر بـ 409. |
| **8** | Idempotency Replay | Ktor Client | إرسال نفس الطلب مرتين بنفس المفتاح. | إعادة الرد السابق دون تكرار أي حركة. |
| **9** | Signed Offline Quota | Crypto Layer | توليد حصة وتوقيعها بـ Ed25519 والتحقق منها. | قبول الحصة السليمة ورفض المزورة. |
| **10** | Disconnect & Resend | Network Emulation | قطع الشبكة أثناء البيع وإعادة الإرسال. | عدم تكرار الفاتورة بعد عودة الشبكة. |
| **11** | Host Crash & Rollback | Process Killer | إيقاف مفاجئ أثناء معاملة بيع غير مكتملة. | تراجع SQLite التام وسلامة نمط WAL. |
| **12** | Database Migration | Migration Engine | تشغيل ترحيل ترقية من إصدار تجريبي. | ترقية الجداول مع الحفاظ على البيانات. |
| **13** | Device Revocation | Admin Auth | إبطال جهاز مسجل واستدعاء API. | حظر الجهاز فوراً برمز 401/403. |
| **14** | Quota Tamper Rejection | Android Client | تعديل كمية الحصة محلياً ومحاولة استخدامها. | رفض الحصة فورياً لفشل التوقيع. |
| **15** | Single Host Instance Lock | OS Process | محاولة تشغيل نسختين من المضيف على نفس المجلد. | فشل النسخة الثانية فوراً وخروجها بأمان. |
| **16** | RTL Thermal Print Simulation | ESC/POS Emulation | إرسال إيصال بيع باللغة العربية لطابعة حرارية. | خروج النص العربي متصلاً وبترتيب سليم. |
| **17** | Multi-item Multi-quota Sale | Offline Engine | بيع 3 أصناف من 3 حصص في فاتورة Offline. | تخصيص السطور للحصص بنجاح وتسويتها. |
| **18** | Offline Numbering Sequence | Sales Engine | توليد إيصال محلي وإسناد رقم رسمي عند التسوية. | عدم وجود فجوات في الترقيم الرسمي. |
| **19** | Encrypted Backup Restore | Crypto & Storage | أخذ نسخة AES-GCM واستعادتها في قاعدة مؤقتة. | تطابق البيانات والـ SHA-256 بنسبة 100%. |
| **20** | Partial Reconciliation Retry | Sync Queue | فشل الاتصال أثناء رفع حزمة مبيعات وإعادتها. | استئناف الرفع بنجاح دون ازدواجية. |

---

## 10. القرارات غير المحسومة والخاضعة للإثبات في PoT

1. **أداء Ed25519 على أجهزة Android القديمة:** قياس زمن التوقيع والتحقق على أجهزة بمواصفات متواضعة (الهدف: أقل من 15 مللي ثانية للعملية).
2. **سلوك Local TLS Certificate Pinning مع Android Network Security Config:** التأكد من قبول الشهادات الذاتية مع عدم إظهار تحذيرات أمنية تعرقل المستخدم.
3. **أداء SQLite في نمط WAL تحت ضغط 5 أجهزة متزامنة عبر LAN:** قياس زمن الاستجابة ومنع حدوث `SQLITE_BUSY` عبر ضبط Timeout = 5000ms.

---

## 11. إقرار النزاهة الهندسية والتوقف التام

- **تم تصحيح وتثبيت الملحق C2 بالكامل في ملف الخطة (`implementation_plan.md`) وفي هذا التقرير.**
- **تم التحقق الفعلي من الـ DDL عبر محرك SQLite 3.40.1 والتأكد من صحة الـ 42 جدولاً وخلوها التام من أي خطأ نحوي أو تركيبي.**
- **لم يتم كتابة أي كود إنتاجي، ولم يتم بدء الوحدة صفر.**
- **لم يُعلن نجاح أي اختبار مسبقاً، واختبارات القبول العشرين هي بوابة العبور بعد موافقتك.**
- **أنا متوقف بالكامل وبانتظار مراجعتك وموافقتك الصريحة للمضي قدماً في تنفيذ الوحدة صفر (PoT).**
