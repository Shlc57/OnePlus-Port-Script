.class public final Lcom/miui/voicetrigger/wakeup/PortCpuKws;
.super Ljava/lang/Object;
.source "PortCpuKws.java"


# interfaces
.implements Ljava/lang/Runnable;


# static fields
.field private static volatile bundle:Landroid/os/Bundle;

.field private static volatile cmdId:Ljava/lang/String;

.field private static volatile deadline:J

.field private static volatile enabled:Z

.field private static volatile listener:Lcom/miui/voicetrigger/wakeup/E;

.field private static final self:Lcom/miui/voicetrigger/wakeup/PortCpuKws;


# direct methods
.method static constructor <clinit>()V
    .locals 1

    new-instance v0, Lcom/miui/voicetrigger/wakeup/PortCpuKws;

    invoke-direct {v0}, Lcom/miui/voicetrigger/wakeup/PortCpuKws;-><init>()V

    sput-object v0, Lcom/miui/voicetrigger/wakeup/PortCpuKws;->self:Lcom/miui/voicetrigger/wakeup/PortCpuKws;

    return-void
.end method

.method private constructor <init>()V
    .locals 0

    invoke-direct {p0}, Ljava/lang/Object;-><init>()V

    return-void
.end method

.method private static schedule(J)V
    .locals 6

    invoke-static {}, Landroid/os/SystemClock;->uptimeMillis()J

    move-result-wide v0

    add-long/2addr v0, p0

    sget-wide v2, Lcom/miui/voicetrigger/wakeup/PortCpuKws;->deadline:J

    cmp-long v4, v2, v0

    if-lez v4, :cond_0

    move-wide v0, v2

    :cond_0
    sput-wide v0, Lcom/miui/voicetrigger/wakeup/PortCpuKws;->deadline:J

    invoke-static {}, Landroid/os/SystemClock;->uptimeMillis()J

    move-result-wide v4

    sub-long/2addr v0, v4

    const-wide/16 v2, 0x0

    cmp-long v4, v0, v2

    if-gez v4, :cond_1

    move-wide v0, v2

    :cond_1
    invoke-static {}, Lv0/N;->d()Landroid/os/Handler;

    move-result-object v2

    sget-object v3, Lcom/miui/voicetrigger/wakeup/PortCpuKws;->self:Lcom/miui/voicetrigger/wakeup/PortCpuKws;

    invoke-virtual {v2, v3}, Landroid/os/Handler;->removeCallbacks(Ljava/lang/Runnable;)V

    invoke-virtual {v2, v3, v0, v1}, Landroid/os/Handler;->postDelayed(Ljava/lang/Runnable;J)Z

    return-void
.end method

.method public static arm(Landroid/os/Bundle;Lcom/miui/voicetrigger/wakeup/E;Ljava/lang/String;J)V
    .locals 0

    sput-object p0, Lcom/miui/voicetrigger/wakeup/PortCpuKws;->bundle:Landroid/os/Bundle;

    sput-object p1, Lcom/miui/voicetrigger/wakeup/PortCpuKws;->listener:Lcom/miui/voicetrigger/wakeup/E;

    sput-object p2, Lcom/miui/voicetrigger/wakeup/PortCpuKws;->cmdId:Ljava/lang/String;

    invoke-static {p3, p4}, Lcom/miui/voicetrigger/wakeup/PortCpuKws;->schedule(J)V

    return-void
.end method

.method public static armStored(J)V
    .locals 0

    invoke-static {p0, p1}, Lcom/miui/voicetrigger/wakeup/PortCpuKws;->schedule(J)V

    return-void
.end method

.method public static setEnabled(Z)V
    .locals 0

    sput-boolean p0, Lcom/miui/voicetrigger/wakeup/PortCpuKws;->enabled:Z

    return-void
.end method

.method public static onWakeup()V
    .locals 8

    :try_start_0
    invoke-static {}, Lh0/c;->a()Landroid/content/Context;

    move-result-object v0

    if-eqz v0, :cond_0

    new-instance v1, Landroid/content/Intent;

    const-string v2, "com.miui.voicetrigger.ACTION_VOICE_TRIGGER_START_VOICEASSIST"

    invoke-direct {v1, v2}, Landroid/content/Intent;-><init>(Ljava/lang/String;)V

    new-instance v2, Landroid/content/ComponentName;

    const-string v3, "com.miui.voiceassist"

    const-string v4, "com.xiaomi.voiceassistant.PermissionVoiceService"

    invoke-direct {v2, v3, v4}, Landroid/content/ComponentName;-><init>(Ljava/lang/String;Ljava/lang/String;)V

    invoke-virtual {v1, v2}, Landroid/content/Intent;->setComponent(Landroid/content/ComponentName;)Landroid/content/Intent;

    const/high16 v2, 0x10000000

    invoke-virtual {v1, v2}, Landroid/content/Intent;->addFlags(I)Landroid/content/Intent;

    const-string v2, "voice_assist_start_from_key"

    const-string v3, "wake_up"

    invoke-virtual {v1, v2, v3}, Landroid/content/Intent;->putExtra(Ljava/lang/String;Ljava/lang/String;)Landroid/content/Intent;

    const-string v2, "intent_type"

    const-string v3, "service"

    invoke-virtual {v1, v2, v3}, Landroid/content/Intent;->putExtra(Ljava/lang/String;Ljava/lang/String;)Landroid/content/Intent;

    const-string v2, "vendor_version"

    const-string v3, "xiaomi"

    invoke-virtual {v1, v2, v3}, Landroid/content/Intent;->putExtra(Ljava/lang/String;Ljava/lang/String;)Landroid/content/Intent;

    sget-object v2, Lcom/miui/voicetrigger/wakeup/PortCpuKws;->cmdId:Ljava/lang/String;

    if-eqz v2, :cond_1

    const-string v2, "XATX"

    :cond_1
    invoke-static {v2}, Lh0/e;->a(Ljava/lang/String;)Ljava/lang/String;

    move-result-object v2

    const-string v3, "wakeup_word"

    invoke-virtual {v1, v3, v2}, Landroid/content/Intent;->putExtra(Ljava/lang/String;Ljava/lang/String;)Landroid/content/Intent;

    invoke-static {}, Ljava/util/UUID;->randomUUID()Ljava/util/UUID;

    move-result-object v2

    invoke-virtual {v2}, Ljava/util/UUID;->toString()Ljava/lang/String;

    move-result-object v2

    const-string v3, "request_id"

    invoke-virtual {v1, v3, v2}, Landroid/content/Intent;->putExtra(Ljava/lang/String;Ljava/lang/String;)Landroid/content/Intent;

    invoke-static {}, Ljava/lang/System;->currentTimeMillis()J

    move-result-wide v2

    const-string v4, "v5.app.wakeup.level1.finish"

    invoke-virtual {v1, v4, v2, v3}, Landroid/content/Intent;->putExtra(Ljava/lang/String;J)Landroid/content/Intent;

    const-string v4, "v5.app.wakeup.level2.finish"

    invoke-virtual {v1, v4, v2, v3}, Landroid/content/Intent;->putExtra(Ljava/lang/String;J)Landroid/content/Intent;

    const-string v4, "v5.app.wakeup.near.awaken.begin"

    invoke-virtual {v1, v4, v2, v3}, Landroid/content/Intent;->putExtra(Ljava/lang/String;J)Landroid/content/Intent;

    const-string v4, "v5.app.wakeup.near.awaken.end"

    invoke-virtual {v1, v4, v2, v3}, Landroid/content/Intent;->putExtra(Ljava/lang/String;J)Landroid/content/Intent;

    const-string v4, "v5.app.wakeup.send.succ.event"

    invoke-virtual {v1, v4, v2, v3}, Landroid/content/Intent;->putExtra(Ljava/lang/String;J)Landroid/content/Intent;

    const-string v4, "other_device_response"

    const/4 v5, 0x0

    invoke-virtual {v1, v4, v5}, Landroid/content/Intent;->putExtra(Ljava/lang/String;Z)Landroid/content/Intent;

    invoke-virtual {v0, v1}, Landroid/content/Context;->startService(Landroid/content/Intent;)Landroid/content/ComponentName;

    const-wide/16 v0, 0x1388

    invoke-static {v0, v1}, Lcom/miui/voicetrigger/wakeup/PortCpuKws;->armStored(J)V
    :try_end_0
    .catchall {:try_start_0 .. :try_end_0} :catchall_0

    goto :goto_0

    :catchall_0
    move-exception v0

    const-string v1, "PortCpuKws"

    const-string v2, "notify voiceassist failed"

    invoke-static {v1, v2, v0}, Lx0/b;->c(Ljava/lang/String;Ljava/lang/String;Ljava/lang/Throwable;)I

    :cond_0
    :goto_0
    return-void
.end method


# virtual methods
.method public run()V
    .locals 6

    const-wide/16 v0, 0x0

    :try_start_0
    sput-wide v0, Lcom/miui/voicetrigger/wakeup/PortCpuKws;->deadline:J

    sget-boolean v0, Lcom/miui/voicetrigger/wakeup/PortCpuKws;->enabled:Z

    if-eqz v0, :cond_ret

    sget-object v1, Lcom/miui/voicetrigger/wakeup/c;->a:Lcom/miui/voicetrigger/wakeup/c;

    invoke-virtual {v1}, Lcom/miui/voicetrigger/wakeup/c;->E()Z

    move-result v2

    if-nez v2, :cond_ret

    invoke-virtual {v1}, Lcom/miui/voicetrigger/wakeup/c;->O()V

    invoke-static {}, Lcom/miui/voicetrigger/wakeup/u;->i()Lcom/miui/voicetrigger/wakeup/u;

    move-result-object v2

    invoke-virtual {v2}, Lcom/miui/voicetrigger/wakeup/u;->e()V

    sget-object v3, Lcom/miui/voicetrigger/wakeup/PortCpuKws;->bundle:Landroid/os/Bundle;

    if-eqz v3, :cond_ret

    sget-object v4, Lcom/miui/voicetrigger/wakeup/PortCpuKws;->listener:Lcom/miui/voicetrigger/wakeup/E;

    if-eqz v4, :cond_ret

    new-instance v5, Landroid/os/Bundle;

    invoke-direct {v5, v3}, Landroid/os/Bundle;-><init>(Landroid/os/Bundle;)V

    invoke-virtual {v2, v5, v4}, Lcom/miui/voicetrigger/wakeup/u;->h(Landroid/os/Bundle;Lcom/miui/voicetrigger/wakeup/E;)I

    new-instance v3, Lcom/miui/voicetrigger/wakeup/u$b;

    invoke-direct {v3, v2}, Lcom/miui/voicetrigger/wakeup/u$b;-><init>(Lcom/miui/voicetrigger/wakeup/u;)V

    sget-object v4, Lcom/miui/voicetrigger/wakeup/PortCpuKws;->cmdId:Ljava/lang/String;

    const/4 v5, 0x0

    invoke-virtual {v1, v5, v5, v3, v4}, Lcom/miui/voicetrigger/wakeup/c;->K(IILcom/miui/voicetrigger/wakeup/x;Ljava/lang/String;)V
    :try_end_0
    .catchall {:try_start_0 .. :try_end_0} :catchall_0

    :cond_ret
    return-void

    :catchall_0
    move-exception v0

    const-string v1, "PortCpuKws"

    const-string v2, "cpu kws re-arm failed"

    invoke-static {v1, v2, v0}, Lx0/b;->c(Ljava/lang/String;Ljava/lang/String;Ljava/lang/Throwable;)I

    return-void
.end method
