//
//  WakeupPlugin.m
//
//  Created by Brad Kammin on 4/29/14.
//
//

#import "WakeupPlugin.h"

#define ALARM_CLOCK_LOCAL_NOTIFICATION  @"AppAlarmClockLocalNotification"

@implementation WakeupPlugin

- (void)pluginInitialize
{
    // watch for local notification
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(_onLocalNotification:) name:CDVLocalNotification object:nil]; // if app is in foreground
    
    NSLog(@"Wakeup Plugin initialized");
}


#pragma mark Plugin methods

- (void)wakeup:(CDVInvokedUrlCommand*)command
{
    CDVPluginResult* pluginResult = nil;
    NSDictionary * options = [command.arguments objectAtIndex:0];
    NSArray * alarms;
    
    if ([options objectForKey:@"alarms"]) {
        alarms = [options objectForKey:@"alarms"];
    } else {
        alarms = [NSArray array]; // empty means cancel all
    }
    
    NSLog(@"scheduling wakeups...");
    
    _callbackId = command.callbackId;
    
    [self _saveToPrefs:alarms];
    
    [self _setAlarms:alarms cancelAlarms:true];
    
    pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK];
    [pluginResult setKeepCallbackAsBool:YES];
    [self.commandDelegate sendPluginResult:pluginResult callbackId:command.callbackId];
}

- (void)snooze:(CDVInvokedUrlCommand *)command
{
    CDVPluginResult* pluginResult = nil;
    NSDictionary * options = [command.arguments objectAtIndex:0];
    NSArray * alarms;
    _callbackId = command.callbackId;
    
    if ([options objectForKey:@"alarms"]) {
        alarms = [options objectForKey:@"alarms"];
        NSLog(@"scheduling snooze...");
        [self _setAlarms:alarms cancelAlarms:false];
    }
    
    pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK];
    [pluginResult setKeepCallbackAsBool:YES];
    [self.commandDelegate sendPluginResult:pluginResult callbackId:command.callbackId];
}

#pragma mark Preference storage methods

- (void)_saveToPrefs:(NSArray *)alarms {
    
    NSError *error;
    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:alarms options:0 error:&error];
    
    if (!jsonData) {
        NSLog(@"error converting NSDictionary to JSON string: %@", error);
    } else {
        NSMutableDictionary *settings = [self _preferences];
        NSString *alarmsJson = [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];
        [settings setValue:alarmsJson forKey:@"alarms"];
        if (![settings writeToFile:[self _prefsFilePath] atomically:YES]) {
            NSLog(@"failed to save preferences to file!");
        }
    }
}

- (NSMutableDictionary *) _preferences
{
    NSMutableDictionary *prefs;
    if ([[NSFileManager defaultManager] fileExistsAtPath: [self _prefsFilePath]]) {
        prefs = [[NSMutableDictionary alloc] initWithContentsOfFile: [self _prefsFilePath]];
        
    } else {
        prefs = [[NSMutableDictionary alloc] initWithCapacity: 10];
        /* set default values */
        [prefs setObject:@{} forKey:@"alarms"];
    }
    return prefs;
};

- (NSString *) _prefsFilePath
{
    NSString *cacheDirectory = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents"];
    NSString *prefsFilePath = [cacheDirectory stringByAppendingPathComponent: @"alarmsettings.plist"];  // TODO - new filename?
    return prefsFilePath;
}

#pragma mark Alarm configuration methods

- (void)_setNotification:(NSString*)type alarmDate:(NSDate*)alarmDate extra:(NSDictionary*)extra message:(NSString*)message action:(NSString*)action  repeatInterval:(int)repeatInterval{
    if(alarmDate){
        UILocalNotification* alarm = [[UILocalNotification alloc] init];
        if (alarm) {
            alarm.fireDate = alarmDate;
            alarm.timeZone = [NSTimeZone defaultTimeZone];
            alarm.repeatInterval = repeatInterval;
            alarm.soundName = UILocalNotificationDefaultSoundName; //@"alarm_clock_2.wav";
            if (message!=nil){
                alarm.alertBody = message;
            } else {
                alarm.alertBody = @"Wake up!";
            }
            
            if (action!=nil){
                alarm.alertAction = action;
            }
            
            NSError *error;
            NSData *jsonData = [NSJSONSerialization dataWithJSONObject:extra options:0 error:&error];
            
            NSString *json = @"{}"; // default empty
            
            if (jsonData) {
                json = [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];
            }
            
            alarm.userInfo = [[NSDictionary alloc] initWithObjectsAndKeys:
                              @"wakeup", @"type",
                              type, @"alarm-type",
                              json,  @"extra", nil];
            
            NSLog(@"scheduling a new alarm local notification for %@", alarm.fireDate);
            
            UIApplication * app = [UIApplication sharedApplication];
            [app scheduleLocalNotification:alarm];
            
            NSTimeInterval time = [alarmDate timeIntervalSince1970];
            NSNumber *timeMs = [NSNumber numberWithDouble:(time * 1000)];
            CDVPluginResult * pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsDictionary:@{@"type": @"set", @"alarm_type":type, @"alarm_date" : timeMs}];
            [pluginResult setKeepCallbackAsBool:YES];
            [self.commandDelegate sendPluginResult:pluginResult callbackId:_callbackId];
        }
    }
}

- (void)_setAlarms:(NSArray *)alarms cancelAlarms:(BOOL)cancelAlarms{
    
	BOOL backgroundSupported = [self _isBackgroundSupported];
    
    if(cancelAlarms) {
        [self _cancelAlarms];
    }
    
    if (backgroundSupported) {
        for (int i=0;i<[alarms count];i++){
            NSDictionary * alarm = alarms[i];
            
            NSString * type=[alarm valueForKeyPath:@"type"];
            NSDictionary * time = [alarm valueForKeyPath:@"time"];
            NSDictionary * extra = [alarm valueForKeyPath:@"extra"];
            NSString * message = [alarm valueForKeyPath:@"message"];
            NSString * action = [alarm valueForKeyPath:@"action"];
            
            if ( type==nil ) {
                type = @"onetime";
            }
            
            // other types to add support for: weekly, daily, weekday, weekend
            if ( [type isEqualToString:@"onetime"]) {
                NSDate * alarmDate = [self _getOneTimeAlarmDate:time];
                [self _setNotification:type alarmDate:alarmDate extra:extra message:message action:action repeatInterval:0];
            } else if ( [type isEqualToString:@"daylist"] ) {
                NSArray * days = [alarm valueForKeyPath:@"days"];
                for (int j=0;j<[days count];j++) {
                    NSDate * alarmDate = [self _getAlarmDate:time day:[self _dayOfWeekIndex:[days objectAtIndex:j]]];
                    [self _setNotification:type alarmDate:alarmDate extra:extra message:message action:action repeatInterval:NSWeekCalendarUnit];
                }
            } else if ( [type isEqualToString:@"snooze"]) {
                [self _cancelSnooze];
                NSDate * alarmDate = [self _getTimeFromNow:time];
                [self _setNotification:type alarmDate:alarmDate extra:extra message:message action:action repeatInterval:0];
            }
            
            NSLog(@"setting alarm...");
        }
    }
    
}

- (void) _cancelAlarms {
    UIApplication * app = [UIApplication sharedApplication];
    NSArray *localNotifications = [app scheduledLocalNotifications];
    
    for (UILocalNotification *not in localNotifications) {
        //NSLog(@"not is %@, user info is %@", not, not.userInfo);
        /* Right now this is cancelling all notifications -- This is because deleting the app doesn't seem to remove old notifications
         * In the future it would be good to remove the YES ||
         */
        /*
        if (YES || [not.userInfo objectForKey:@"alarm"]) {
            //NSLog(@"cancelling existing alarm notification");
            [app cancelLocalNotification:not];
        } else {
            //NSLog(@"non-alarm notification -- not cancelling");
        }
         */
        NSString * type = [not.userInfo objectForKey:@"type"];
        if (type && [type isEqualToString:@"wakeup"]) {
            NSLog(@"cancelling existing alarm notification");
            [app cancelLocalNotification:not];
        }
        
    }
    //[self performSelector:@selector(allowDeepSleepIfAlarmIsOff) withObject:nil afterDelay:60*15];
    
}

- (void) _cancelSnooze {
    UIApplication * app = [UIApplication sharedApplication];
    NSArray *localNotifications = [app scheduledLocalNotifications];
    
    for (UILocalNotification *not in localNotifications) {
        //NSLog(@"not is %@, user info is %@", not, not.userInfo);
        NSString * type = [not.userInfo objectForKey:@"alarm-type"];
        if (type && [type isEqualToString:@"snooze"]) {
            NSLog(@"cancelling existing alarm notification");
            [app cancelLocalNotification:not];
        }
    }
    //[self performSelector:@selector(allowDeepSleepIfAlarmIsOff) withObject:nil afterDelay:60*15];
    
}

- (BOOL) _isBackgroundSupported
{
	UIDevice* device = [UIDevice currentDevice];
	BOOL backgroundSupported = NO;
	if ([device respondsToSelector:@selector(isMultitaskingSupported)]) {
		backgroundSupported = device.multitaskingSupported;
	}
	return backgroundSupported;
}

-(NSDate*) _getOneTimeAlarmDate:(NSDictionary*)time {
    NSDate *alarmDate = nil;
    NSDate * now = [NSDate date];
    int hour=[time objectForKey:@"hour"]!=nil ? [[time objectForKey:@"hour"] intValue] : -1;
    int minute=[time objectForKey:@"minute"]!=nil ? [[time objectForKey:@"minute"] intValue] : 0;
    NSCalendar * gregorian = [[NSCalendar alloc] initWithCalendarIdentifier:NSGregorianCalendar];
    NSDateComponents *nowComponents =[gregorian components:(NSYearCalendarUnit | NSMonthCalendarUnit | NSDayCalendarUnit) fromDate:now]; // set to current day
    [nowComponents setHour:hour];
    [nowComponents setMinute:minute];
    [nowComponents setSecond:0];
    alarmDate = [gregorian dateFromComponents:nowComponents];

    if ( [alarmDate compare:now]==NSOrderedAscending){
        NSDateComponents * addDayComponents = [[NSDateComponents alloc] init];
        [addDayComponents setDay:1];
        alarmDate = [gregorian dateByAddingComponents:addDayComponents toDate:alarmDate options:0];
    }
    
    return alarmDate;
}

-(NSDate*) _getAlarmDate:(NSDictionary*)time day:(int)dayOfWeek {
    NSDate *alarmDate = nil;
    NSDate * now = [NSDate date];
    unsigned nowSeconds=[self _secondOfTheDay:now];
    
    int hour=[time objectForKey:@"hour"]!=nil ? [[time objectForKey:@"hour"] intValue] : -1;
    int minute=[time objectForKey:@"minute"]!=nil ? [[time objectForKey:@"minute"] intValue] : 0;
    
    if (hour>=0 && dayOfWeek >= 0) {
        NSCalendar * gregorian = [[NSCalendar alloc] initWithCalendarIdentifier:NSGregorianCalendar];
        NSDateComponents *nowComponents =[gregorian components:(NSYearCalendarUnit | NSMonthCalendarUnit | NSDayCalendarUnit) fromDate:now];
        [nowComponents setHour:hour];
        [nowComponents setMinute:minute];
        [nowComponents setSecond:0];
        
        gregorian = [[NSCalendar alloc] initWithCalendarIdentifier:NSGregorianCalendar];
        NSDateComponents *weekdayComponents =[gregorian components:NSWeekdayCalendarUnit fromDate:[NSDate date]];
        NSInteger currentDayOfWeek = [weekdayComponents weekday]; // 1-7 = Sunday-Saturday
        currentDayOfWeek--; // make zero-based
        
        // add number of days until 'dayOfWeek' occurs
        alarmDate = [gregorian dateFromComponents:nowComponents];
        unsigned alarmSeconds=[self _secondOfTheDay:alarmDate];
        
        int daysUntilAlarm=0;
        if(currentDayOfWeek>dayOfWeek){
            // currentDayOfWeek=thursday (4); alarm=monday (1) -- add 4 days
            daysUntilAlarm=(6-currentDayOfWeek) + dayOfWeek + 1; // (days until the end of week) + dayOfWeek + 1
        }else if(currentDayOfWeek<dayOfWeek){
            // example: currentDayOfWeek=monday (1); dayOfWeek=thursday (4) -- add three days
            daysUntilAlarm=dayOfWeek-currentDayOfWeek;
        }else{
            if(alarmSeconds > nowSeconds){
                daysUntilAlarm=0;
            }else{
                daysUntilAlarm=7;
            }
        }
        
        NSDateComponents * addDayComponents = [[NSDateComponents alloc] init];
        [addDayComponents setDay:(daysUntilAlarm)];
        alarmDate = [gregorian dateByAddingComponents:addDayComponents toDate:alarmDate options:0];

        
    }
    
	return alarmDate;
}

-(NSDate*) _getTimeFromNow:(NSDictionary*)time {
    NSDate *alarmDate = [NSDate date];

    int seconds=[time objectForKey:@"seconds"]!=nil ? [[time objectForKey:@"seconds"] intValue] : -1;

    if (seconds>=0){
        NSCalendar * gregorian = [[NSCalendar alloc] initWithCalendarIdentifier:NSGregorianCalendar];
        NSDateComponents * addSeconds = [[NSDateComponents alloc] init];
        [addSeconds setSecond:seconds];
        alarmDate = [gregorian dateByAddingComponents:addSeconds toDate:alarmDate options:0];
    } else {
        alarmDate=nil;
    }
    return alarmDate;
}

- (unsigned) _secondOfTheDay:(NSDate*) time
{
    // extracts hour/minutes/seconds from NSDate, converts to seconds since midnight
    NSCalendar* curCalendar = [NSCalendar currentCalendar];
    const unsigned units    = NSHourCalendarUnit | NSMinuteCalendarUnit | NSSecondCalendarUnit;
    NSDateComponents* comps = [curCalendar components:units fromDate:time];
    int hour = [comps hour];
    int min  = [comps minute];
    int sec  = [comps second];
    
    return ((hour * 60) + min) * 60 + sec;
}

-(int) _dayOfWeekIndex:(NSString*)day {
    int dayIndex=-1;
    if ( [day isEqualToString:@"sunday"]){
        dayIndex = 0;
    } else if ( [day isEqualToString:@"monday"]){
        dayIndex = 1;
    } else if ( [day isEqualToString:@"tuesday"]){
        dayIndex = 2;
    } else if ( [day isEqualToString:@"wednesday"]){
        dayIndex = 3;
    } else if ( [day isEqualToString:@"thursday"]){
        dayIndex = 4;
    } else if ( [day isEqualToString:@"friday"]){
        dayIndex = 5;
    } else if ( [day isEqualToString:@"saturday"]){
        dayIndex = 6;
    }
    return dayIndex;
}

#pragma mark Wakeup handlers

- (void)_onLocalNotification:(NSNotification *)notification
{
    NSLog(@"Wakeup Plugin received local notification while app is running");
    
    UILocalNotification* localNotification = [notification object];
    NSString * notificationType = [[localNotification userInfo] objectForKey:@"type"];
    
    if ( notificationType!=nil && [notificationType isEqualToString:@"wakeup"] && _callbackId!=nil) {
        NSLog(@"wakeup detected!");
        NSString * extra = [[localNotification userInfo] objectForKey:@"extra"];
        CDVPluginResult * pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsDictionary:@{@"type": @"wakeup", @"extra" : extra}];
        [pluginResult setKeepCallbackAsBool:YES];
        [self.commandDelegate sendPluginResult:pluginResult callbackId:_callbackId];
    }

}

#pragma mark Cleanup

- (void)dispose {
    NSLog(@"Wakeup Plugin disposing");
    [[NSNotificationCenter defaultCenter] removeObserver:self name:CDVLocalNotification object:nil];
    [super dispose];
}

@end
