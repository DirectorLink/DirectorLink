-- The words of DirectorLink's alerts on a screen (1.13.0, ADR-086, docs/NOTIFY_DRIVERS.md): the
-- title and the message a TV of DirectorLink's notification agreement shows (src/core/notify.lua),
-- made on the controller in the home owner's language (their profile's, docs/PREFERENCES.md;
-- English when it is Auto or unknown). They are the app's own sentences for the same alert on a
-- phone (app/sw.js sealedNotice, with the words app/js/alerts.js alertTexts gives it), copied here
-- under the app's keys: driver/tests/test_notify.lua fails when one here is not the app's, in any of
-- the four languages, so the two never drift. Change a sentence in app/i18n/*.js and here together.

local NotifyWords = {}

-- Hebrew reads right to left: its title and message begin with U+200F RIGHT-TO-LEFT MARK, so that a
-- screen that takes the direction from the first letter (a name in Latin letters: "Gate", "Control4")
-- still lays the sentence out right to left. Invisible otherwise.
local RIGHT_TO_LEFT = { he = true }
local RLM = "\226\128\143"

-- The sentences, by the app's key (app/i18n/<language>.js), in the order the phone uses them.
NotifyWords.WORDS = {
    -- English: app/i18n/en.js
    en = {
        ["alerts.title"] = "DirectorLink",
        ["alerts.yourHome"] = "Your home",
        ["alerts.other"] = "{home} – something needs your attention. Open the app to see what happened.",
        ["alerts.scheduleFailed"] = "{home} – a schedule had a problem at {time}. Open the app to see what happened.",
        ["alerts.scheduleFailedNamed"] = "{home} – the schedule for {name} had a problem at {time}. Open the app to see what happened.",
        ["doorbells.notificationTitle"] = "Someone is at the door",
        ["alerts.doorbell"] = "{name} rang at {time}.",
        ["alerts.doorOpened"] = "{name} was opened by {who} at {time}.",
        ["alerts.doorOpenedScene"] = "{name} was opened by {who}, with the scene {scene}, at {time}.",
        ["alerts.doorOpenedControl4"] = "{name} was opened in Control4 at {time}.",
        ["alerts.doorHeld"] = "{name} was held open by {who} at {time}.",
        ["alerts.who"] = "{person} ({device})",
        ["history.who.unknownDevice"] = "a removed device",
        ["alerts.fridgeDoor"] = "{name} – the door has been open for at least {minutes} min ({time}).",
        ["alerts.fridgeDoorNow"] = "{name} – the door was left open ({time}).",
        ["alerts.cameraTitle"] = "Camera alert",
        ["alerts.camera"] = "{what} at {name} at {time}.",
        ["alerts.cameraSaw.person"] = "Person",
        ["alerts.cameraSaw.vehicle"] = "Vehicle",
        ["alerts.cameraSaw.animal"] = "Animal",
        ["alerts.cameraSaw.package"] = "Package",
        ["alerts.cameraSaw.license_plate"] = "License plate",
        ["alerts.cameraSaw.face"] = "Face",
        ["alerts.cameraSaw.motion"] = "Motion",
        ["alerts.cameraSaw.line_crossing"] = "Line crossed",
        ["alerts.cameraSaw.intrusion"] = "Intrusion",
        ["alerts.cameraSaw.region_entrance"] = "Someone entering",
        ["alerts.cameraSaw.region_exiting"] = "Someone leaving",
        ["alerts.cameraSaw.tamper"] = "Tampering",
        ["alerts.cameraSaw.scene_change"] = "View changed",
        ["alerts.cameraSaw.object_left"] = "Object left behind",
        ["alerts.cameraSaw.object_removed"] = "Object removed",
        ["alerts.cameraSaw.alarm_input"] = "Alarm input",
        ["alerts.cameraSaw.pir"] = "Motion (PIR)",
        ["alerts.cameraSaw.smoke_alarm"] = "Smoke alarm",
        ["alerts.cameraSaw.co_alarm"] = "CO alarm",
        ["alerts.cameraSaw.siren"] = "Siren",
        ["alerts.cameraSaw.baby_crying"] = "Baby crying",
        ["alerts.cameraSaw.speech"] = "Someone talking",
        ["alerts.cameraSaw.barking"] = "Dog barking",
        ["alerts.cameraSaw.burglar_alarm"] = "Burglar alarm",
        ["alerts.cameraSaw.car_horn"] = "Car horn",
        ["alerts.cameraSaw.glass_break"] = "Glass breaking",
        ["alerts.cameraSaw.other"] = "Alert",
    },
    -- Hebrew: app/i18n/he.js
    he = {
        ["alerts.title"] = "DirectorLink",
        ["alerts.yourHome"] = "הבית שלכם",
        ["alerts.other"] = "{home} – משהו דורש את תשומת לבכם. פתחו את האפליקציה כדי לראות מה קרה.",
        ["alerts.scheduleFailed"] = "{home} – תזמון נתקל בבעיה ב-{time}. פתחו את האפליקציה כדי לראות מה קרה.",
        ["alerts.scheduleFailedNamed"] = "{home} – התזמון של {name} נתקל בבעיה ב-{time}. פתחו את האפליקציה כדי לראות מה קרה.",
        ["doorbells.notificationTitle"] = "מישהו בדלת",
        ["alerts.doorbell"] = "צלצול ב-{name} ב-{time}.",
        ["alerts.doorOpened"] = "פתיחה של {name} על ידי {who} ב-{time}.",
        ["alerts.doorOpenedScene"] = "פתיחה של {name} על ידי {who}, בסצנה {scene}, ב-{time}.",
        ["alerts.doorOpenedControl4"] = "פתיחה של {name} דרך Control4 ב-{time}.",
        ["alerts.doorHeld"] = "החזקה במצב פתוח של {name} על ידי {who} ב-{time}.",
        ["alerts.who"] = "{person} ({device})",
        ["history.who.unknownDevice"] = "מכשיר שהוסר",
        ["alerts.fridgeDoor"] = "{name} – הדלת פתוחה כבר לפחות {minutes} דק׳ ({time}).",
        ["alerts.fridgeDoorNow"] = "{name} – הדלת נשארה פתוחה ({time}).",
        ["alerts.cameraTitle"] = "התראת מצלמה",
        ["alerts.camera"] = "{what} ב-{name} ב-{time}.",
        ["alerts.cameraSaw.person"] = "אדם",
        ["alerts.cameraSaw.vehicle"] = "רכב",
        ["alerts.cameraSaw.animal"] = "בעל חיים",
        ["alerts.cameraSaw.package"] = "חבילה",
        ["alerts.cameraSaw.license_plate"] = "לוחית רישוי",
        ["alerts.cameraSaw.face"] = "פנים",
        ["alerts.cameraSaw.motion"] = "תנועה",
        ["alerts.cameraSaw.line_crossing"] = "חציית קו",
        ["alerts.cameraSaw.intrusion"] = "חדירה",
        ["alerts.cameraSaw.region_entrance"] = "כניסה לאזור",
        ["alerts.cameraSaw.region_exiting"] = "יציאה מאזור",
        ["alerts.cameraSaw.tamper"] = "חבלה במצלמה",
        ["alerts.cameraSaw.scene_change"] = "שינוי בתמונה",
        ["alerts.cameraSaw.object_left"] = "חפץ שהושאר",
        ["alerts.cameraSaw.object_removed"] = "חפץ שהוסר",
        ["alerts.cameraSaw.alarm_input"] = "כניסת אזעקה",
        ["alerts.cameraSaw.pir"] = "תנועה (PIR)",
        ["alerts.cameraSaw.smoke_alarm"] = "גלאי עשן",
        ["alerts.cameraSaw.co_alarm"] = "גלאי פחמן חד-חמצני",
        ["alerts.cameraSaw.siren"] = "סירנה",
        ["alerts.cameraSaw.baby_crying"] = "בכי תינוק",
        ["alerts.cameraSaw.speech"] = "דיבור",
        ["alerts.cameraSaw.barking"] = "נביחות",
        ["alerts.cameraSaw.burglar_alarm"] = "אזעקת פריצה",
        ["alerts.cameraSaw.car_horn"] = "צופר רכב",
        ["alerts.cameraSaw.glass_break"] = "שבירת זכוכית",
        ["alerts.cameraSaw.other"] = "התראה",
    },
    -- Spanish: app/i18n/es.js
    es = {
        ["alerts.title"] = "DirectorLink",
        ["alerts.yourHome"] = "Tu casa",
        ["alerts.other"] = "{home} – algo requiere tu atención. Abre la app para ver qué pasó.",
        ["alerts.scheduleFailed"] = "{home} – una programación tuvo un problema a las {time}. Abre la app para ver qué pasó.",
        ["alerts.scheduleFailedNamed"] = "{home} – la programación de {name} tuvo un problema a las {time}. Abre la app para ver qué pasó.",
        ["doorbells.notificationTitle"] = "Hay alguien en la puerta",
        ["alerts.doorbell"] = "{name} sonó a las {time}.",
        ["alerts.doorOpened"] = "{who} abrió {name} a las {time}.",
        ["alerts.doorOpenedScene"] = "{who} abrió {name} con la escena {scene} a las {time}.",
        ["alerts.doorOpenedControl4"] = "Se abrió {name} desde Control4 a las {time}.",
        ["alerts.doorHeld"] = "{who} mantuvo {name} en posición abierta a las {time}.",
        ["alerts.who"] = "{person} ({device})",
        ["history.who.unknownDevice"] = "un dispositivo eliminado",
        ["alerts.fridgeDoor"] = "{name} – la puerta lleva abierta al menos {minutes} min ({time}).",
        ["alerts.fridgeDoorNow"] = "{name} – la puerta se quedó abierta ({time}).",
        ["alerts.cameraTitle"] = "Alerta de cámara",
        ["alerts.camera"] = "{what} en {name} a las {time}.",
        ["alerts.cameraSaw.person"] = "Persona",
        ["alerts.cameraSaw.vehicle"] = "Vehículo",
        ["alerts.cameraSaw.face"] = "Rostro",
        ["alerts.cameraSaw.motion"] = "Movimiento",
        ["alerts.cameraSaw.line_crossing"] = "Cruce de línea",
        ["alerts.cameraSaw.intrusion"] = "Intrusión",
        ["alerts.cameraSaw.region_entrance"] = "Alguien entrando",
        ["alerts.cameraSaw.region_exiting"] = "Alguien saliendo",
        ["alerts.cameraSaw.tamper"] = "Sabotaje",
        ["alerts.cameraSaw.scene_change"] = "Cambio de vista",
        ["alerts.cameraSaw.object_left"] = "Objeto abandonado",
        ["alerts.cameraSaw.object_removed"] = "Objeto retirado",
        ["alerts.cameraSaw.alarm_input"] = "Entrada de alarma",
        ["alerts.cameraSaw.pir"] = "Movimiento (PIR)",
        ["alerts.cameraSaw.other"] = "Alerta",
        ["alerts.cameraSaw.animal"] = "Animal",
        ["alerts.cameraSaw.package"] = "Paquete",
        ["alerts.cameraSaw.license_plate"] = "Matrícula",
        ["alerts.cameraSaw.smoke_alarm"] = "Alarma de humo",
        ["alerts.cameraSaw.co_alarm"] = "Alarma de CO",
        ["alerts.cameraSaw.siren"] = "Sirena",
        ["alerts.cameraSaw.baby_crying"] = "Bebé llorando",
        ["alerts.cameraSaw.speech"] = "Alguien hablando",
        ["alerts.cameraSaw.barking"] = "Perro ladrando",
        ["alerts.cameraSaw.burglar_alarm"] = "Alarma antirrobo",
        ["alerts.cameraSaw.car_horn"] = "Claxon",
        ["alerts.cameraSaw.glass_break"] = "Rotura de cristal",
    },
    -- Italian: app/i18n/it.js
    it = {
        ["alerts.title"] = "DirectorLink",
        ["alerts.yourHome"] = "La tua casa",
        ["alerts.other"] = "{home} – qualcosa richiede la tua attenzione. Apri l’app per vedere cosa è successo.",
        ["alerts.scheduleFailed"] = "{home} – una programmazione ha avuto un problema alle {time}. Apri l’app per vedere cosa è successo.",
        ["alerts.scheduleFailedNamed"] = "{home} – la programmazione di {name} ha avuto un problema alle {time}. Apri l’app per vedere cosa è successo.",
        ["doorbells.notificationTitle"] = "C’è qualcuno alla porta",
        ["alerts.doorbell"] = "{name} ha suonato alle {time}.",
        ["alerts.doorOpened"] = "{who} ha aperto {name} alle {time}.",
        ["alerts.doorOpenedScene"] = "{who} ha aperto {name} con la scena {scene} alle {time}.",
        ["alerts.doorOpenedControl4"] = "Apertura di {name} tramite Control4 alle {time}.",
        ["alerts.doorHeld"] = "{who} ha messo {name} in apertura continua alle {time}.",
        ["alerts.who"] = "{person} ({device})",
        ["history.who.unknownDevice"] = "un dispositivo rimosso",
        ["alerts.fridgeDoor"] = "{name} – la porta è aperta da almeno {minutes} min ({time}).",
        ["alerts.fridgeDoorNow"] = "{name} – la porta è rimasta aperta ({time}).",
        ["alerts.cameraTitle"] = "Avviso telecamera",
        ["alerts.camera"] = "{what} presso {name} alle {time}.",
        ["alerts.cameraSaw.person"] = "Persona",
        ["alerts.cameraSaw.vehicle"] = "Veicolo",
        ["alerts.cameraSaw.face"] = "Volto",
        ["alerts.cameraSaw.motion"] = "Movimento",
        ["alerts.cameraSaw.line_crossing"] = "Linea attraversata",
        ["alerts.cameraSaw.intrusion"] = "Intrusione",
        ["alerts.cameraSaw.region_entrance"] = "Qualcuno entra",
        ["alerts.cameraSaw.region_exiting"] = "Qualcuno esce",
        ["alerts.cameraSaw.tamper"] = "Manomissione",
        ["alerts.cameraSaw.scene_change"] = "Inquadratura cambiata",
        ["alerts.cameraSaw.object_left"] = "Oggetto abbandonato",
        ["alerts.cameraSaw.object_removed"] = "Oggetto rimosso",
        ["alerts.cameraSaw.alarm_input"] = "Ingresso allarme",
        ["alerts.cameraSaw.pir"] = "Movimento (PIR)",
        ["alerts.cameraSaw.other"] = "Avviso",
        ["alerts.cameraSaw.animal"] = "Animale",
        ["alerts.cameraSaw.package"] = "Pacco",
        ["alerts.cameraSaw.license_plate"] = "Targa",
        ["alerts.cameraSaw.smoke_alarm"] = "Allarme fumo",
        ["alerts.cameraSaw.co_alarm"] = "Allarme CO",
        ["alerts.cameraSaw.siren"] = "Sirena",
        ["alerts.cameraSaw.baby_crying"] = "Bambino che piange",
        ["alerts.cameraSaw.speech"] = "Qualcuno parla",
        ["alerts.cameraSaw.barking"] = "Cane che abbaia",
        ["alerts.cameraSaw.burglar_alarm"] = "Allarme antifurto",
        ["alerts.cameraSaw.car_horn"] = "Clacson",
        ["alerts.cameraSaw.glass_break"] = "Vetro rotto",
    },
}

-- `code` when DirectorLink has words in it (en, he, es, it), else English (Auto, unknown, nil).
function NotifyWords.language(code)
    if type(code) == "string" and NotifyWords.WORDS[code] then
        return code
    end
    return "en"
end

-- A name worth saying: text with something in it, else nil (as the service worker's `text`).
local function text(value)
    if type(value) == "string" and value:find("%S") then
        return value
    end
    return nil
end

-- `template` with each {name} replaced by `values[name]` ("" when it has none), as the app's fill.
local function fill(template, values)
    return (template:gsub("{(%w+)}", function(name)
        local value = values[name]
        return value == nil and "" or tostring(value)
    end))
end

-- Who opened a door, as the history says it: the user and the device (the phone's whoText).
local function whoText(who, word)
    local device = text(who.name) or word("history.who.unknownDevice")
    local person = text(who.profile)
    if person and person ~= device then
        return fill(word("alerts.who"), { person = person, device = device })
    end
    return device
end

-- What a screen shows for `detail`, an alert as the controller seals it for a phone
-- (src/cloud/alerts.lua: its kind, name, what, action, via, who, minutes), raised at `at` (seconds,
-- shown in the controller's time, 24-hour, as a phone shows it in its own): the title and the
-- message in `language` (NotifyWords.language). An alert without the name it needs gets the
-- general words, as on a phone.
function NotifyWords.say(detail, language, at)
    local code = NotifyWords.language(language)
    local words = NotifyWords.WORDS[code]
    local function word(key)
        return words[key] or NotifyWords.WORDS.en[key]
    end
    detail = type(detail) == "table" and detail or {}
    local time = os.date("%H:%M", tonumber(at) or os.time())
    local name = text(detail.name)
    local home = word("alerts.yourHome")
    local title, message
    if detail.kind == "doorbell" and name then
        title, message = word("doorbells.notificationTitle"), fill(word("alerts.doorbell"), { name = name, time = time })
    elseif detail.kind == "camera" and name then
        local what = type(detail.what) == "string" and words["alerts.cameraSaw." .. detail.what] or word("alerts.cameraSaw.other")
        title, message = word("alerts.cameraTitle"), fill(word("alerts.camera"), { what = what, name = name, time = time })
    elseif detail.kind == "door_opened" and name then
        local by = type(detail.who) == "table" and detail.who or {}
        local scene = text(detail.via)
        local key = "alerts.doorOpened"
        if by.type == "control4" then
            key = "alerts.doorOpenedControl4"
        elseif detail.action == "hold" then
            key = "alerts.doorHeld"
        elseif scene then
            key = "alerts.doorOpenedScene"
        end
        title, message = word("alerts.title"), fill(word(key), { name = name, who = whoText(by, word), scene = scene, time = time })
    elseif detail.kind == "fridge_door" and name then
        local minutes = type(detail.minutes) == "number" and detail.minutes >= 1 and math.floor(detail.minutes) or nil
        title = word("alerts.title")
        message = fill(word(minutes and "alerts.fridgeDoor" or "alerts.fridgeDoorNow"), { name = name, minutes = minutes, time = time })
    elseif detail.kind == "schedule_failed" then
        title = word("alerts.title")
        message = fill(word(name and "alerts.scheduleFailedNamed" or "alerts.scheduleFailed"), { home = home, name = name, time = time })
    else
        title, message = word("alerts.title"), fill(word("alerts.other"), { home = home })
    end
    if RIGHT_TO_LEFT[code] then
        title, message = RLM .. title, RLM .. message
    end
    return title, message
end

return NotifyWords
