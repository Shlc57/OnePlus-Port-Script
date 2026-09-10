.class public Lcom/miui/voicetrigger/wakeup/PortWakeupHooks;
.super Ljava/lang/Object;
.source "PortWakeupHooks.smali"


# direct methods
.method public constructor <init>()V
    .locals 0

    invoke-direct {p0}, Ljava/lang/Object;-><init>()V

    return-void
.end method

.method private static clampInt(III)I
    .locals 1

    invoke-static {p0, p2}, Ljava/lang/Math;->min(II)I

    move-result p0

    invoke-static {p1, p0}, Ljava/lang/Math;->max(II)I

    move-result p0

    return p0
.end method

.method private static getIntProp(Ljava/lang/String;III)I
    .locals 2

    :try_start_0
    const-string v0, ""

    invoke-static {p0, v0}, Landroid/os/SystemProperties;->get(Ljava/lang/String;Ljava/lang/String;)Ljava/lang/String;

    move-result-object v0

    invoke-static {v0}, Ljava/lang/Integer;->parseInt(Ljava/lang/String;)I

    move-result v0

    invoke-static {v0, p2, p3}, Lcom/miui/voicetrigger/wakeup/PortWakeupHooks;->clampInt(III)I

    move-result v0
    :try_end_0
    .catch Ljava/lang/Throwable; {:try_start_0 .. :try_end_0} :catch_0

    return v0

    :catch_0
    move-exception v0

    return p1
.end method

.method private static putIntLE([BII)V
    .locals 2

    # 前提：p2 为非负 int（调用方已钳制 0..5000）。smali 移位指令字面量
    # 范围受限（-8..7），改用连续除法提取各字节，非负值下与 >>8/>>16/>>24 等价。
    int-to-byte v0, p2

    aput-byte v0, p0, p1

    div-int/lit16 v0, p2, 0x100

    int-to-byte v0, v0

    add-int/lit8 v1, p1, 0x1

    aput-byte v0, p0, v1

    div-int/lit16 v0, p2, 0x100

    div-int/lit16 v0, v0, 0x100

    int-to-byte v0, v0

    add-int/lit8 v1, p1, 0x2

    aput-byte v0, p0, v1

    div-int/lit16 v0, p2, 0x100

    div-int/lit16 v0, v0, 0x100

    div-int/lit16 v0, v0, 0x100

    int-to-byte v0, v0

    add-int/lit8 v1, p1, 0x3

    aput-byte v0, p0, v1

    return-void
.end method


# virtual methods
.method public static buildLabData()[B
    .locals 5

    const/16 v0, 0x14

    new-array v0, v0, [B

    const/4 v1, 0x0

    const/4 v2, 0x1

    aput-byte v2, v0, v1

    const/4 v1, 0x4

    const/16 v2, 0xc

    aput-byte v2, v0, v1

    const/16 v1, 0x8

    const/4 v2, 0x2

    aput-byte v2, v0, v1

    const-string v1, "persist.sys.xiaoai.lab_history_ms"

    const/16 v2, 0x9c4

    const/16 v3, 0x3e8

    const/16 v4, 0x1388

    invoke-static {v1, v2, v3, v4}, Lcom/miui/voicetrigger/wakeup/PortWakeupHooks;->getIntProp(Ljava/lang/String;III)I

    move-result v1

    const/16 v2, 0xc

    invoke-static {v0, v2, v1}, Lcom/miui/voicetrigger/wakeup/PortWakeupHooks;->putIntLE([BII)V

    const-string v1, "persist.sys.xiaoai.lab_preroll_ms"

    const/16 v2, 0x3e8

    const/4 v3, 0x0

    const/16 v4, 0xbb8

    invoke-static {v1, v2, v3, v4}, Lcom/miui/voicetrigger/wakeup/PortWakeupHooks;->getIntProp(Ljava/lang/String;III)I

    move-result v1

    const/16 v2, 0x10

    invoke-static {v0, v2, v1}, Lcom/miui/voicetrigger/wakeup/PortWakeupHooks;->putIntLE([BII)V

    return-object v0
.end method
