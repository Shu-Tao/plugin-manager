#import "PMHostNames.h"

static NSDictionary<NSString *, NSString *> *PMHostTable(void) {
    static NSDictionary *table = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        table = @{
            // 系统核心
            @"com.apple.springboard": @"桌面",
            @"com.apple.UIKit": @"全系统 UI",
            @"com.apple.Preferences": @"设置",
            @"com.apple.SpotLight": @"搜索",
            @"com.apple.springboard.lockdown": @"锁屏",
            @"com.apple.springboardhome": @"桌面",

            // 系统服务 / 守护进程
            @"securityd": @"安全服务",
            @"mediaremoted": @"媒体服务",
            @"MobileGestaltHelper": @"设备信息",
            @"aggregated": @"系统日志",
            @"backboardd": @"触控与背光",
            @"assertiond": @"进程守护",
            @"runningboardd": @"进程管理",
            @"launchd": @"系统启动",
            @"lsd": @"应用注册",
            @"itunesstored": @"App Store",
            @"storebookkeeperd": @"商店服务",
            @"passd": @"钱包",
            @"akd": @"Apple ID",
            @"identityservicesd": @"iMessage / FaceTime",
            @"sharingd": @"隔空投送",
            @"bird": @"iCloud 同步",
            @"cloudd": @"iCloud",
            @"nsurlsessiond": @"下载服务",
            @"installd": @"应用安装",
            @"mobileassetd": @"系统资源",
            @"dasd": @"后台调度",
            @"duetexpertd": @"智能预测",
            @"suggestd": @"建议",
            @"coreduetd": @"使用习惯",
            @"biometrickitd": @"生物识别",
            @"wifid": @"WiFi",
            @"CommCenter": @"蜂窝网络",
            @"bluetoothd": @"蓝牙",
            @"mediaserverd": @"音视频",
            @"audioaccessoryd": @"音频配件",
            @"corespeechd": @"语音识别",
            @"assistantd": @"Siri",
            @"Siri": @"Siri",
            @"voiced": @"语音",
            @"healthd": @"健康",
            @"locationd": @"定位",
            @"routined": @"位置历史",
            @"Contacts": @"通讯录",
            @"MobileSMS": @"信息",
            @"MobileMail": @"邮件",
            @"MobileCalendar": @"日历",
            @"MobileNotes": @"备忘录",
            @"MobileTimer": @"时钟",
            @"Camera": @"相机",
            @"Photos": @"照片",
            @"MobileMusicPlayer": @"音乐",
            @"Videos": @"视频",
            @"MobilePhone": @"电话",
            @"IncomingCall": @"来电",
            @"callservicesd": @"通话服务",
            @"ChatKit": @"iMessage 界面",
            @"IMCore": @"信息核心",
            @"MobileSafari": @"Safari",
            @"WebKit": @"网页引擎",
            @"com.apple.mobilesafari": @"Safari",
            @"com.apple.mobilemail": @"邮件",
            @"com.apple.MobileSMS": @"信息",
            @"com.apple.mobileslideshow": @"照片",
            @"com.apple.camera": @"相机",
            @"com.apple.Music": @"音乐",
            @"com.apple.videos": @"视频",
            @"com.apple.mobilephone": @"电话",
            @"com.apple.mobiletimer": @"时钟",
            @"com.apple.mobilenotes": @"备忘录",
            @"com.apple.mobilecal": @"日历",
            @"com.apple.reminders": @"提醒事项",
            @"com.apple.Health": @"健康",
            @"com.apple.Maps": @"地图",
            @"com.apple.weather": @"天气",
            @"com.apple.stocks": @"股市",
            @"com.apple.news": @"新闻",
            @"com.apple.Passbook": @"钱包",
            @"com.apple.clockface": @"时钟表盘",
            @"com.apple.controlcenter": @"控制中心",
            @"com.apple.notificationsettings": @"通知设置",
            @"com.apple.MobileAddressBook": @"通讯录",
            @"com.apple.facetime": @"FaceTime",
            @"com.apple.AppStore": @"App Store",
            @"com.apple.mobileipod": @"音乐",
            @"com.apple.shortcuts": @"快捷指令",
            @"com.apple.VoiceMemos": @"语音备忘录",
            @"com.apple.compass": @"指南针",
            @"com.apple.calculator": @"计算器",
            @"com.apple.DocumentsApp": @"文件",

            // 常见越狱宿主
            @"com.apple.dock": @"Dock",
            @"Anemone": @"主题",
            @"SpringBoard": @"桌面",
        };
    });
    return table;
}

NSString *PMDescribeHost(NSString *identifier) {
    if (identifier.length == 0) return nil;
    NSDictionary *table = PMHostTable();
    NSString *hit = table[identifier];
    if (hit) return hit;

    // 大小写不敏感兜底（Bundle ID 偶有大小写差异）
    NSString *lower = identifier.lowercaseString;
    for (NSString *key in table) {
        if (key.lowercaseString == lower || [key.lowercaseString isEqualToString:lower]) {
            return table[key];
        }
    }

    // com.apple.xxx.yyy 形式：取最后一段当名字
    if ([lower hasPrefix:@"com.apple."]) {
        NSString *tail = [identifier substringFromIndex:@"com.apple.".length];
        return [NSString stringWithFormat:@"系统 %@", tail];
    }
    return nil;
}

NSString *PMDescribeTargets(NSArray<NSString *> *bundles, NSArray<NSString *> *executables) {
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    NSMutableSet<NSString *> *seen = [NSMutableSet set];

    for (NSString *b in bundles) {
        NSString *human = PMDescribeHost(b) ?: b;
        if ([seen containsObject:human]) continue;
        [seen addObject:human];
        [names addObject:human];
    }
    for (NSString *e in executables) {
        NSString *human = PMDescribeHost(e) ?: e;
        if ([seen containsObject:human]) continue;
        [seen addObject:human];
        [names addObject:human];
    }

    if (names.count == 0) return @"未声明作用范围";
    if (names.count <= 3) return [names componentsJoinedByString:@"、"];
    NSArray *head = [names subarrayWithRange:NSMakeRange(0, 3)];
    return [NSString stringWithFormat:@"%@ 等 %lu 处",
            [head componentsJoinedByString:@"、"], (unsigned long)names.count];
}
