--version is: 4
--Last Revision date: 27/03/26 19:30:00
--%%name:AMS Reader
--%%type:com.fibaro.genericDevice
--%%var:Setup="0"
--%%var:AMS_IP="192.168.30.82"
--%%var:Username=""
--%%var:Password=""
--%%project:276
--%%file:C:\Users\GREENCOM\Workspace\PLUA\63.AMSreader/AMS_Reader_276_Qwikchild.lua,Qwikchild
--%%file:C:\Users\GREENCOM\Workspace\PLUA\63.AMSreader/AMS_Reader_276_Icons.lua,Icons
--%%file:C:\Users\GREENCOM\Workspace\PLUA\63.AMSreader/AMS_Reader_276_Monthplot.lua,Monthplot
--%%u:{label="Info",text="Info"}
--%%u:{label="info_price",text=""}
--%%u:{label="info_tariff",text=""}
--%%u:{label="info_energyaccounting",text=""}
--%%u:{label="info_hours",text=""}
--%%u:{label="info_days",text=""}
--%%u:{label="info_months",text=""}
--%%u:{label="info_ams",text=""}
--%%u:{label="info_url",text=""}
--%%u:{label="error_status",text=""}
--%%u:{button="t1",text="Read Config",onReleased="t1"}
--%%u:{button="t2",text="Read Prices",onReleased="t2"}


---@diagnostic disable-next-line

  
--[[
MIT License

Copyright (c) 2025 Brors94

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

]]
-------------------------------------------------------------------------------------------------------------------------------
-------------------------------------------------------------------------------------------------------------------------------
-- Constants and configuration
local config = {
    update_interval = 30*1000,   --- 30000 = 30sec
    min_update_interval = 2500,  --- minimum data.json poll interval in ms
    live_ui_refresh_interval = 10*1000, --- throttle heavy live UI card refreshes in ms
    http_timeout = 10000,        --- HTTP timeout in ms
    sysinfo_refresh_interval = 60*60, --- refresh static system info every hour
    configuration_refresh_interval = 60*60, --- refresh configuration endpoint every hour
    hourly_sync_offsets = {
        energyprice = 20,        --- hh:00:20
        dayplot = 25,            --- hh:00:25
        monthplot = 30,          --- hh:00:30
        tariff = 35,             --- hh:00:35
        sysinfo = 40,            --- hh:00:40
        configuration = 45,      --- hh:00:45
    },
    power_factor_fallback_after_fails = 10, --- calculate overall power factor after this many failed raw readings
    power_factor_refresh_interval = 60, --- refresh overall power factor child in sec
    offline_after_http_failures = 10, --- mark AMS offline after this many consecutive data.json fetch failures
    hour_history_limit = 48,     --- number of completed hourly values to keep in storage
    hour_history_ignore_above_kwh = 10000, --- replace hourly history spikes above this value with the previous hour (or 0)
    month_history_limit = 31,    --- number of rolling daily values to keep in storage
    month_totals_history_limit = 240, --- number of monthly totals to keep in storage
    refresh_mem_interval = 60,   --- system status / GC refresh in sec
    gc_collect_interval = 5*60,  --- force a full Lua GC at most every 5 min during steady state
    gc_collect_threshold_kb = 3000, --- force a full Lua GC sooner if current memory exceeds this threshold






        start_time = os.clock(),
        start_date = os.date(),
        -- Theme colors — edit here, no QA variables needed
        colors = {
            color1 = "#e8890c",   -- titles / labels  (orange)
            color2 = "#34c759",   -- values           (green)
            color4 = "#2196f3",   -- headings / info  (blue)
        },
        -- UI layout
        ui = {
            widthPx       = 400,
            titleFontSize = 4,
            bodyFontSize  = 2,
            colLeft       = 200,
            divider       = { color = "DarkSeaGreen", sizePx = 4 },
        },

        debug = false, -- set to true to enable extra debug logging in the HC3 console
}

local function get_data_update_interval_ms()
    local interval = tonumber(config.update_interval) or 0
    if interval <= 0 then return 0 end

    local min_interval = tonumber(config.min_update_interval) or 2500
    return math.max(min_interval, interval)
end

local function get_live_ui_refresh_interval_ms()
    local interval = tonumber(config.live_ui_refresh_interval) or (10 * 1000)
    if interval <= 0 then
        return get_data_update_interval_ms()
    end

    return math.max(get_data_update_interval_ms(), interval)
end

local function trim_text(value)
    return tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

local function base64Encode(data)
    local alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
    local text = tostring(data or "")
    if text == "" then return "" end

    return ((text:gsub(".", function(char)
        local value = char:byte()
        local bits = {}
        for index = 8, 1, -1 do
            bits[#bits+1] = value % 2^index - value % 2^(index - 1) > 0 and "1" or "0"
        end
        return table.concat(bits)
    end) .. "0000"):gsub("%d%d%d?%d?%d?%d?", function(bits)
        if #bits < 6 then return "" end
        local value = 0
        for index = 1, 6 do
            if bits:sub(index, index) == "1" then
                value = value + 2^(6 - index)
            end
        end
        return alphabet:sub(value + 1, value + 1)
    end) .. ({ "", "==", "=" })[#text % 3 + 1])
end

local function get_ams_credentials(self)
    local username = trim_text(self:getVariable("Username"))
    local password = tostring(self:getVariable("Password") or "")
    if username == "" and password == "" then
        return nil, nil
    end
    return username, password
end

local function get_ams_auth_header(self)
    local username, password = get_ams_credentials(self)
    if username == nil then return nil end
    return "Basic " .. base64Encode(username .. ":" .. password)
end

local function get_ams_auth_status_text(self)
    local mode = type(self.runtime) == "table" and tostring(self.runtime.ams_auth_mode or "unknown") or "unknown"
    local username, password = get_ams_credentials(self)
    local has_credentials = username ~= nil or (password ~= nil and password ~= "")

    if mode == "required" then
        return "Enabled"
    end
    if mode == "disabled" then
        return "Disabled"
    end
    if mode == "failed" then
        return "Failed"
    end
    if has_credentials then
        return "Auto"
    end
    return "Disabled"
end

local function get_main_log_text()
    local interval_ms = get_data_update_interval_ms()
    if interval_ms <= 0 then
        return "🕐 Interval off"
    end

    local interval_seconds = interval_ms / 1000
    if math.floor(interval_seconds) == interval_seconds then
        return "🕐 Interval " .. tostring(math.floor(interval_seconds)) .. "sec"
    end

    return string.format("🕐 Interval %.1fsec", interval_seconds)
end

print("Start Time: ",config.start_time)


-------------------------------------------------------------------------------------------------------------------------------
-------------------------------------------------------------------------------------------------------------------------------





local Child_table = {  
["s1"] = {
    name = "AMS Active import",
    type = "com.fibaro.powerMeter",
    className = 'powerMeterChild',
    properties={rateType="consumption"},
    interfaces={},
    store = {
        value = "",
        unit="W",
        includeInEnergyPanel = true,
    },
    UI = {{label='Info', text='Info'},},
    
},
["s2"] = {
    name = "AMS Active export",
    type = "com.fibaro.powerMeter",
    className = 'powerMeterChild',
    properties={rateType="production"},
    interfaces={},
    store = {
        value = "",
        unit="W",
        includeInEnergyPanel = true,
    },
    UI = {{label='Info', text='Info'},},
    
},
["s3"] = {
    name = "AMS Active import/export",
    type = "com.fibaro.powerMeter",
    className = 'powerMeterChild',
    properties={rateType="consumption"},
    interfaces={},
    store = {
        value = "",
        unit="W",
    },
    UI = {{label='Info', text='Info'},},
    
},
["s4"] = {
    name = "AMS Reactive import",
    type = "com.fibaro.multilevelSensor",
    className = 'multilevelSensor',
    properties={},
    interfaces={},
    store = {
        value = "",
        unit="var",
    },
    UI = {{label='Info', text='Info'},},
    
},
["s5"] = {
    name = "AMS Reactive export",
    type = "com.fibaro.multilevelSensor",
    className = 'multilevelSensor',
    properties={},
    interfaces={},
    store = {
        value = "",
        unit="var",
    },
    UI = {{label='Info', text='Info'},},
    
},
["s6"] = {
    name = "AMS Accumulated import",
    type = "com.fibaro.energyMeter",
    className = 'energyMeterChild',
    properties={rateType="consumption"},
    interfaces={},
    store = {
        value = "",
        unit="kWh",
        saveToEnergyPanel = true,
    },
    UI = {{label='Info', text='Info'},},
    
},
["s7"] = {
    name = "AMS Accumulated export",
    type = "com.fibaro.energyMeter",
    className = 'energyMeterChild',
    properties={rateType="production"},
    interfaces={},
    store = {
        value = "",
        unit="kWh",
        saveToEnergyPanel = true,
    },
    UI = {{label='Info', text='Info'},},
    
},
["s8"] = {
    name = "AMS Accumulated reactive import",
    type = "com.fibaro.multilevelSensor",
    className = 'multilevelSensor',
    properties={},
    interfaces={},
    store = {
        value = "",
        unit="varh",
    },
    UI = {{label='Info', text='Info'},},
    
},
["s9"] = {
    name = "AMS Accumulated reactive export",
    type = "com.fibaro.multilevelSensor",
    className = 'multilevelSensor',
    properties={},
    interfaces={},
    store = {
        value = "",
        unit="varh",
    },
    UI = {{label='Info', text='Info'},},
    
},


["s10"] = {
    name = "AMS L1 Voltage",
    type = "com.fibaro.multilevelSensor",
    className = 'multilevelSensor',
    properties={},
    interfaces={},
    store = {
        value = "",
        unit="V",
    },
    UI = {{label='Info', text='Info'},},
    
},
["s11"] = {
    name = "AMS L1 Amperage",
    type = "com.fibaro.multilevelSensor",
    className = 'multilevelSensor',
    properties={},
    interfaces={},
    store = {
        value = "",
        unit="A",
    },
    UI = {{label='Info', text='Info'},},
    
},
["s12"] = {
    name = "AMS L1 Active Power",
    type = "com.fibaro.multilevelSensor",
    className = 'multilevelSensor',
    properties={},
    interfaces={},
    store = {
        value = "",
        unit="W",
    },
    UI = {{label='Info', text='Info'},},
    
},
["s13"] = {
    name = "AMS L1 Reactive Power",
    type = "com.fibaro.multilevelSensor",
    className = 'multilevelSensor',
    properties={},
    interfaces={},
    store = {
        value = "",
        unit="var",
    },
    UI = {{label='Info', text='Info'},},
    
},
["s14"] = {
    name = "AMS L1 Power Factor",
    type = "com.fibaro.multilevelSensor",
    className = 'multilevelSensor',
    properties={},
    interfaces={},
    store = {
        value = "",
        unit="cos",
    },
    UI = {{label='Info', text='Info'},},
    
},



["s15"] = {
    name = "AMS L2 Voltage",
    type = "com.fibaro.multilevelSensor",
    className = 'multilevelSensor',
    properties={},
    interfaces={},
    store = {
        value = "",
        unit="V",
    },
    UI = {{label='Info', text='Info'},},
    
},
["s16"] = {
    name = "AMS L2 Amperage",
    type = "com.fibaro.multilevelSensor",
    className = 'multilevelSensor',
    properties={},
    interfaces={},
    store = {
        value = "",
        unit="A",
    },
    UI = {{label='Info', text='Info'},},
    
},
["s17"] = {
    name = "AMS L2 Active Power",
    type = "com.fibaro.multilevelSensor",
    className = 'multilevelSensor',
    properties={},
    interfaces={},
    store = {
        value = "",
        unit="W",
    },
    UI = {{label='Info', text='Info'},},
    
},
["s18"] = {
    name = "AMS L2 Reactive Power",
    type = "com.fibaro.multilevelSensor",
    className = 'multilevelSensor',
    properties={},
    interfaces={},
    store = {
        value = "",
        unit="var",
    },
    UI = {{label='Info', text='Info'},},
    
},
["s19"] = {
    name = "AMS L2 Power Factor",
    type = "com.fibaro.multilevelSensor",
    className = 'multilevelSensor',
    properties={},
    interfaces={},
    store = {
        value = "",
        unit="cos",
    },
    UI = {{label='Info', text='Info'},},
    
},




["s20"] = {
    name = "AMS L3 Voltage",
    type = "com.fibaro.multilevelSensor",
    className = 'multilevelSensor',
    properties={},
    interfaces={},
    store = {
        value = "",
        unit="V",
    },
    UI = {{label='Info', text='Info'},},
    
},
["s21"] = {
    name = "AMS L3 Amperage",
    type = "com.fibaro.multilevelSensor",
    className = 'multilevelSensor',
    properties={},
    interfaces={},
    store = {
        value = "",
        unit="A",
    },
    UI = {{label='Info', text='Info'},},
    
},
["s22"] = {
    name = "AMS L3 Active Power",
    type = "com.fibaro.multilevelSensor",
    className = 'multilevelSensor',
    properties={},
    interfaces={},
    store = {
        value = "",
        unit="W",
    },
    UI = {{label='Info', text='Info'},},
    
},
["s23"] = {
    name = "AMS L3 Reactive Power",
    type = "com.fibaro.multilevelSensor",
    className = 'multilevelSensor',
    properties={},
    interfaces={},
    store = {
        value = "",
        unit="var",
    },
    UI = {{label='Info', text='Info'},},
    
},
["s24"] = {
    name = "AMS L3 Power Factor",
    type = "com.fibaro.multilevelSensor",
    className = 'multilevelSensor',
    properties={},
    interfaces={},
    store = {
        value = "",
        unit="cos",
    },
    UI = {{label='Info', text='Info'},},

},

["s25"] = {
    name = "Import This Hour",
    type = "com.fibaro.energyMeter",
    className = 'energyMeterChild',
    properties={rateType="consumption"},
    interfaces={},
    store = {
        value = 0,
        unit="kWh",
    },
    UI = {{label='Info', text='Info'},},
},
["s26"] = {
    name = "Import Last Hour",
    type = "com.fibaro.energyMeter",
    className = 'energyMeterChild',
    properties={rateType="consumption"},
    interfaces={},
    store = {
        value = 0,
        unit="kWh",
    },
    UI = {{label='Info', text='Info'},},
},

["s27"] = {
    name = "Import Today",
    type = "com.fibaro.energyMeter",
    className = 'energyMeterChild',
    properties={rateType="consumption"},
    interfaces={},
    store = {
        value = 0,
        unit="kWh",
    },
    UI = {{label='Info', text='Info'},},
},
["s28"] = {
    name = "Import Yesterday",
    type = "com.fibaro.energyMeter",
    className = 'energyMeterChild',
    properties={rateType="consumption"},
    interfaces={},
    store = {
        value = 0,
        unit="kWh",
    },
    UI = {{label='Info', text='Info'},},
},

["s29"] = {
    name = "Monthly Peak 1",
    type = "com.fibaro.energyMeter",
    className = 'energyMeterChild',
    properties={rateType="consumption"},
    interfaces={},
    store = {
        value = 0,
        unit="kWh",
    },
    UI = {{label='Info', text='Info'},},
},
["s30"] = {
    name = "Monthly Peak 2",
    type = "com.fibaro.energyMeter",
    className = 'energyMeterChild',
    properties={rateType="consumption"},
    interfaces={},
    store = {
        value = 0,
        unit="kWh",
    },
    UI = {{label='Info', text='Info'},},
},
["s31"] = {
    name = "Monthly Peak 3",
    type = "com.fibaro.energyMeter",
    className = 'energyMeterChild',
    properties={rateType="consumption"},
    interfaces={},
    store = {
        value = 0,
        unit="kWh",
    },
    UI = {{label='Info', text='Info'},},
},
["s32"] = {
    name = "Monthly Avg Peak",
    type = "com.fibaro.energyMeter",
    className = 'energyMeterChild',
    properties={rateType="consumption"},
    interfaces={},
    store = {
        value = 0,
        unit="kWh",
    },
    UI = {{label='Info', text='Info'},},
},
["s33"] = {
    name = "AMS Current Import Price",
    type = "com.fibaro.multilevelSensor",
    className = 'multilevelSensor',
    properties={},
    interfaces={},
    store = {
        value = 0,
        unit="kr/kWh",
    },
    UI = {{label='Info', text='Info'},},
},
["s34"] = {
    name = "AMS Current Export Price",
    type = "com.fibaro.multilevelSensor",
    className = 'multilevelSensor',
    properties={},
    interfaces={},
    store = {
        value = 0,
        unit="kr/kWh",
    },
    UI = {{label='Info', text='Info'},},
},
["s35"] = {
    name = "This Hour Cost",
    type = "com.fibaro.multilevelSensor",
    className = 'multilevelSensor',
    properties={},
    interfaces={},
    store = {
        value = 0,
        unit="kr",
    },
    UI = {{label='Info', text='Info'},},
},
["s36"] = {
    name = "This Hour Export",
    type = "com.fibaro.energyMeter",
    className = 'energyMeterChild',
    properties={rateType="production"},
    interfaces={},
    store = {
        value = 0,
        unit="kWh",
    },
    UI = {{label='Info', text='Info'},},
},
["s37"] = {
    name = "This Hour Income",
    type = "com.fibaro.multilevelSensor",
    className = 'multilevelSensor',
    properties={},
    interfaces={},
    store = {
        value = 0,
        unit="kr",
    },
    UI = {{label='Info', text='Info'},},
},
["s38"] = {
    name = "Cost Today",
    type = "com.fibaro.multilevelSensor",
    className = 'multilevelSensor',
    properties={},
    interfaces={},
    store = {
        value = 0,
        unit="kr",
    },
    UI = {{label='Info', text='Info'},},
},
["s39"] = {
    name = "Export Today",
    type = "com.fibaro.energyMeter",
    className = 'energyMeterChild',
    properties={rateType="production"},
    interfaces={},
    store = {
        value = 0,
        unit="kWh",
    },
    UI = {{label='Info', text='Info'},},
},
["s40"] = {
    name = "Income Today",
    type = "com.fibaro.multilevelSensor",
    className = 'multilevelSensor',
    properties={},
    interfaces={},
    store = {
        value = 0,
        unit="kr",
    },
    UI = {{label='Info', text='Info'},},
},
["s41"] = {
    name = "AMS Power Factor",
    type = "com.fibaro.multilevelSensor",
    className = 'multilevelSensor',
    properties={},
    interfaces={},
    store = {
        value = 0,
        unit="cos",
    },
    UI = {{label='Info', text='Info'},},
},
["s42"] = {
    name = "AMS L1 Apparent Power",
    type = "com.fibaro.multilevelSensor",
    className = 'multilevelSensor',
    properties={},
    interfaces={},
    store = {
        value = "",
        unit="VA",
    },
    UI = {{label='Info', text='Info'},},
},
["s43"] = {
    name = "AMS L2 Apparent Power",
    type = "com.fibaro.multilevelSensor",
    className = 'multilevelSensor',
    properties={},
    interfaces={},
    store = {
        value = "",
        unit="VA",
    },
    UI = {{label='Info', text='Info'},},
},
["s44"] = {
    name = "AMS L3 Apparent Power",
    type = "com.fibaro.multilevelSensor",
    className = 'multilevelSensor',
    properties={},
    interfaces={},
    store = {
        value = "",
        unit="VA",
    },
    UI = {{label='Info', text='Info'},},
},
["s45"] = {
    name = "Import This Month",
    type = "com.fibaro.energyMeter",
    className = 'energyMeterChild',
    properties={rateType="consumption"},
    interfaces={},
    store = {
        value = 0,
        unit="kWh",
    },
    UI = {{label='Info', text='Info'},},
},
["s46"] = {
    name = "Cost This Month",
    type = "com.fibaro.multilevelSensor",
    className = 'multilevelSensor',
    properties={},
    interfaces={},
    store = {
        value = 0,
        unit="kr",
    },
    UI = {{label='Info', text='Info'},},
},
["s47"] = {
    name = "Export This Month",
    type = "com.fibaro.energyMeter",
    className = 'energyMeterChild',
    properties={rateType="production"},
    interfaces={},
    store = {
        value = 0,
        unit="kWh",
    },
    UI = {{label='Info', text='Info'},},
},
["s48"] = {
    name = "Income This Month",
    type = "com.fibaro.multilevelSensor",
    className = 'multilevelSensor',
    properties={},
    interfaces={},
    store = {
        value = 0,
        unit="kr",
    },
    UI = {{label='Info', text='Info'},},
},
["s49"] = {
    name = "AMS Online",
    type = "com.fibaro.binarySensor",
    className = 'binarySensorChild',
    properties={},
    interfaces={},
    store = {
        value = true,
    },
    UI = {{label='Info', text='Info'},},
},


}----- end Child_table
----------------------------------------------------------------------------------------------------
----------------------------------------------------------------------------------------------------

class 'powerMeterChild'(QwikAppChild)
---@diagnostic disable-next-line: undefined-global
function powerMeterChild:__init(dev)
QwikAppChild.__init(self,dev)

end
------------------------------
---@diagnostic disable-next-line: undefined-global
function powerMeterChild:update(Child_table,uid)
local value = Child_table[uid].store.value
local rateType = (Child_table[uid].properties and Child_table[uid].properties.rateType) or "consumption"

self:updateView('Info',"text", tostring(value).." "..Child_table[uid].store.unit)

self:updateProperty('value', value)
self:updateProperty('log', os.date("%H:%M"))
self:updateProperty('unit', Child_table[uid].store.unit)
self:updateProperty('rateType', rateType)
self:updateProperty('includeInEnergyPanel', Child_table[uid].store.includeInEnergyPanel == true)

end

----------------------------------------------------------------------------------------------------
----------------------------------------------------------------------------------------------------

class 'multilevelSensor'(QwikAppChild)
---@diagnostic disable-next-line: undefined-global
function multilevelSensor:__init(dev)
QwikAppChild.__init(self,dev)

end
------------------------------
---@diagnostic disable-next-line: undefined-global
function multilevelSensor:update(Child_table,uid)
local value = Child_table[uid].store.value

self:updateView('Info',"text", tostring(value).." "..Child_table[uid].store.unit)

self:updateProperty('value', value)
self:updateProperty('log', os.date("%H:%M"))
self:updateProperty('unit', Child_table[uid].store.unit)

end

----------------------------------------------------------------------------------------------------
----------------------------------------------------------------------------------------------------

class 'energyMeterChild'(QwikAppChild)
---@diagnostic disable-next-line: undefined-global
function energyMeterChild:__init(dev)
QwikAppChild.__init(self,dev)

end
------------------------------
---@diagnostic disable-next-line: undefined-global
function energyMeterChild:update(Child_table,uid)
local value = Child_table[uid].store.value
local rateType = (Child_table[uid].properties and Child_table[uid].properties.rateType) or "consumption"

self:updateView('Info',"text", tostring(value).." "..Child_table[uid].store.unit)

self:updateProperty('value', value)
self:updateProperty('log', os.date("%H:%M"))
self:updateProperty('unit', Child_table[uid].store.unit)
self:updateProperty('rateType', rateType)
self:updateProperty('storeEnergyData', true)
self:updateProperty('saveToEnergyPanel', Child_table[uid].store.saveToEnergyPanel == true)

end

----------------------------------------------------------------------------------------------------
----------------------------------------------------------------------------------------------------

class 'binarySensorChild'(QwikAppChild)
---@diagnostic disable-next-line: undefined-global
function binarySensorChild:__init(dev)
QwikAppChild.__init(self,dev)

end
------------------------------
---@diagnostic disable-next-line: undefined-global
function binarySensorChild:update(Child_table,uid)
local value = Child_table[uid].store.value == true

self:updateView('Info',"text", value and "Online" or "Offline")

self:updateProperty('value', value)
self:updateProperty('log', os.date("%H:%M"))

end

----------------------------------------------------------------------------------------------------
----------------------------------------------------------------------------------------------------






















----------------------------------------------------------------------------------------------------
----------------------------------------------------------------------------------------------------


-------------------------------------------------------------------------------------------------------------------------------
-------------------------------------------------------------------------------------------------------------------------------
---@diagnostic disable-next-line
function QuickApp:setupStorage()
local storage,qa = {},self
function storage:__index(key) return qa:internalStorageGet(key) end
function storage:__newindex(key,val)
    if val == nil then qa:internalStorageRemove(key)
    else qa:internalStorageSet(key,val) end
    end
return setmetatable({},storage) 
end
-------------------------------------------------------------------------------------------------------------------------------
-------------------------------------------------------------------------------------------------------------------------------






-------------------------------------------------------------------------------------------------------------------------------
-------------------------------------------------------------------------------------------------------------------------------
local AMS_ICON_CONFIG = {
    storagePrefix = "ams_icon",
    verifyDelayMs = 800,
    verifyMaxTries = 4,
    installDelayMs = 1500,
    uploadTimeoutMs = 30000,
    uploadRetryDelayMs = 2500,
    uploadMaxAttempts = 3,
    buttonSizePx = 96,
    warningColor = "#ffb347",
    genericType = "com.fibaro.genericDevice",
}

local function amsIconStorageKey(suffix)
    return AMS_ICON_CONFIG.storagePrefix .. "_" .. tostring(suffix or "")
end

local function normalizeBase64Data(data)
    return (tostring(data or ""):gsub("%s+", ""))
end

local function getAmsIconBase64()
    return normalizeBase64Data(amsreader_icon)
end

local function getAmsIconFingerprint(base64Data)
    local base64Text = normalizeBase64Data(base64Data)
    if base64Text == "" then return "" end

    return table.concat({
        tostring(#base64Text),
        base64Text:sub(1, 24),
        base64Text:sub(-24),
    }, ":")
end

local function base64Decode(data)
    local alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
    local base64Text = normalizeBase64Data(data)
    if base64Text == "" then return "" end

    return ((base64Text:gsub(".", function(char)
        if char == "=" then return "" end

        local value = alphabet:find(char, 1, true)
        if value == nil then return "" end
        value = value - 1

        local bits = {}
        for index = 6, 1, -1 do
            bits[#bits+1] = value % 2^index - value % 2^(index - 1) > 0 and "1" or "0"
        end
        return table.concat(bits)
    end)):gsub("%d%d%d?%d?%d?%d?%d?%d?", function(bits)
        if #bits ~= 8 then return "" end

        local value = 0
        for index = 1, 8 do
            if bits:sub(index, index) == "1" then
                value = value + 2^(8 - index)
            end
        end
        return string.char(value)
    end))
end

local function getAmsIconDataUrl()
    local base64Text = getAmsIconBase64()
    if base64Text == "" then return nil end
    return "data:image/png;base64," .. base64Text
end

local function clearAmsIconMarkers(self)
    self:internalStorageRemove(amsIconStorageKey("state"))
    self:internalStorageRemove(amsIconStorageKey("id"))
    self:internalStorageRemove(amsIconStorageKey("fingerprint"))
end

local function getAmsDeviceIconState(self)
    local ok, device = pcall(api.get, "/devices/" .. tostring(self.id))
    if not ok or type(device) ~= "table" then
        return nil, ok and "Missing device data" or tostring(device)
    end

    local properties = type(device.properties) == "table" and device.properties or {}
    local icon = type(properties.icon) == "table" and properties.icon or {}

    return {
        deviceIcon = tonumber(properties.deviceIcon),
        iconPath = tostring(icon.path or ""),
        deviceType = tostring(device.type or self.type or ""),
    }
end

local function getStoredAmsIconId(self)
    local storedIconId = tonumber(self:internalStorageGet(amsIconStorageKey("id")))
    if storedIconId ~= nil and storedIconId > 0 then return storedIconId end

    local iconState = getAmsDeviceIconState(self)
    if type(iconState) == "table" and tonumber(iconState.deviceIcon) ~= nil and tonumber(iconState.deviceIcon) > 0 then
        return tonumber(iconState.deviceIcon)
    end

    return nil
end

local function getStoredAmsInstallState(self)
    local state = tostring(self:internalStorageGet(amsIconStorageKey("state")) or "")
    if state == "verified" or state == "deviceIconOnly" or state == "uploaded" then
        return state
    end
    return nil
end

local function finishAmsIconInstall(self, ok, iconId, state, message, cb)
    if not ok then
        clearAmsIconMarkers(self)
        if cb then
            cb(false, message, state)
        else
            self:warning(tostring(message))
        end
        return
    end

    self:internalStorageSet(amsIconStorageKey("state"), state)
    self:internalStorageSet(amsIconStorageKey("id"), tonumber(iconId) or iconId)
    self:internalStorageSet(amsIconStorageKey("fingerprint"), getAmsIconFingerprint(getAmsIconBase64()))

    if cb then
        cb(true, iconId, state)
        return
    end

    if state == "deviceIconOnly" then
        self:warning(tostring(message))
    else
        self:debug(tostring(message))
    end
end

local verifyAmsIconInstall

verifyAmsIconInstall = function(self, iconId, setIcon, cb, attempt)
    if setIcon ~= true then
        finishAmsIconInstall(self, true, iconId, "uploaded", "AMS icon uploaded without applying deviceIcon", cb)
        return
    end

    local iconState, err = getAmsDeviceIconState(self)
    if type(iconState) ~= "table" then
        if attempt < AMS_ICON_CONFIG.verifyMaxTries then
            hub.setTimeout(AMS_ICON_CONFIG.verifyDelayMs, function()
                verifyAmsIconInstall(self, iconId, setIcon, cb, attempt + 1)
            end)
            return
        end
        finishAmsIconInstall(self, false, nil, "verifyError", "AMS icon verification failed: " .. tostring(err), cb)
        return
    end

    if tonumber(iconState.deviceIcon) ~= tonumber(iconId) then
        if attempt < AMS_ICON_CONFIG.verifyMaxTries then
            hub.setTimeout(AMS_ICON_CONFIG.verifyDelayMs, function()
                verifyAmsIconInstall(self, iconId, setIcon, cb, attempt + 1)
            end)
            return
        end
        finishAmsIconInstall(self, false, nil, "verifyError", "HC3 did not keep AMS deviceIcon " .. tostring(iconId), cb)
        return
    end

    if iconState.iconPath ~= "" then
        finishAmsIconInstall(self, true, iconId, "verified", "AMS icon stored with path " .. tostring(iconState.iconPath), cb)
        return
    end

    if iconState.deviceType == AMS_ICON_CONFIG.genericType then
        finishAmsIconInstall(
            self,
            true,
            iconId,
            "deviceIconOnly",
            "HC3 stored AMS deviceIcon " .. tostring(iconId) .. " for genericDevice without a reusable icon path",
            cb
        )
        return
    end

    if attempt < AMS_ICON_CONFIG.verifyMaxTries then
        hub.setTimeout(AMS_ICON_CONFIG.verifyDelayMs, function()
            verifyAmsIconInstall(self, iconId, setIcon, cb, attempt + 1)
        end)
        return
    end

    finishAmsIconInstall(self, false, nil, "verifyError", "HC3 accepted the AMS icon id but did not resolve the icon path", cb)
end

function QuickApp:installAmsIconClear()
    clearAmsIconMarkers(self)
end

local function shouldRetryAmsIconUploadError(err)
    local message = tostring(err or ""):lower()
    return message:find("operation canceled", 1, true) ~= nil
        or message:find("timeout", 1, true) ~= nil
        or message:find("timed out", 1, true) ~= nil
end

function QuickApp:installAmsIcon(setIcon, cb, timeout, attempt)
    attempt = math.max(1, tonumber(attempt) or 1)
    local base64Text = getAmsIconBase64()
    if base64Text == "" then
        finishAmsIconInstall(self, false, nil, "missingIcon", "AMS icon base64 payload is missing", cb)
        return
    end

    local fingerprint = getAmsIconFingerprint(base64Text)
    local storedFingerprint = tostring(self:internalStorageGet(amsIconStorageKey("fingerprint")) or "")
    if storedFingerprint ~= "" and storedFingerprint ~= fingerprint then
        clearAmsIconMarkers(self)
    end

    local state = getStoredAmsInstallState(self)
    local storedIconId = getStoredAmsIconId(self)
    if state == "verified" or state == "uploaded" or state == "deviceIconOnly" then
        if setIcon == true and storedIconId ~= nil then
            pcall(self.updateProperty, self, "deviceIcon", storedIconId)
        end
        if cb then cb(true, storedIconId, state) end
        return
    end

    local binaryIcon = base64Decode(base64Text)
    if binaryIcon == "" then
        finishAmsIconInstall(self, false, nil, "decodeError", "AMS icon base64 decode returned an empty payload", cb)
        return
    end

    local http = net.HTTPClient
    local ok, err = pcall(function()
        function net.HTTPClient(_)
            return http({ timeout = timeout or AMS_ICON_CONFIG.uploadTimeoutMs or 30000 })
        end

        local types = self.deviceIconTypeMapping and self.deviceIconTypeMapping[self.type]
        assert(types, "Unsupported device type")

        local fileNames = type(types.fileNames) == "table" and types.fileNames or {}
        assert(#fileNames > 0, "No icon fileNames available for device type")

        local iconFiles = {}
        for _ = 1, #fileNames do
            iconFiles[#iconFiles+1] = binaryIcon
        end

        local data = {
            files = iconFiles,
            fileNames = fileNames,
            deviceType = self.type,
        }

        self:uploadIconFiles(data, {}, function(id)
            local iconId = tonumber(id) or id
            if setIcon == true then
                pcall(self.updateProperty, self, "deviceIcon", iconId)
            end
            verifyAmsIconInstall(self, iconId, setIcon, cb, 1)
        end, function(uploadErr)
            local message = tostring(uploadErr)
            if attempt < (tonumber(AMS_ICON_CONFIG.uploadMaxAttempts) or 3) and shouldRetryAmsIconUploadError(message) then
                self:warning("AMS icon upload retry " .. tostring(attempt) .. ": " .. message)
                hub.setTimeout(tonumber(AMS_ICON_CONFIG.uploadRetryDelayMs) or 2500, function()
                    self:installAmsIcon(setIcon, cb, timeout, attempt + 1)
                end)
                return
            end
            finishAmsIconInstall(self, false, nil, "uploadError", message, cb)
        end)
    end)

    net.HTTPClient = http
    if not ok then
        local message = tostring(err)
        if attempt < (tonumber(AMS_ICON_CONFIG.uploadMaxAttempts) or 3) and shouldRetryAmsIconUploadError(message) then
            self:warning("AMS icon upload retry " .. tostring(attempt) .. ": " .. message)
            hub.setTimeout(tonumber(AMS_ICON_CONFIG.uploadRetryDelayMs) or 2500, function()
                self:installAmsIcon(setIcon, cb, timeout, attempt + 1)
            end)
            return
        end
        finishAmsIconInstall(self, false, nil, "uploadError", message, cb)
    end
end

-- Helper functions before QuickApp methods
local function dbg_value(value)
    if type(value) ~= "table" then
        return value
    end

    local ok, encoded = pcall(json.encode, value)
    if ok and type(encoded) == "string" and encoded ~= "" then
        return encoded
    end

    return tostring(value)
end

local function dbg(...)
    if config.debug then
        local parts = {}
        for index = 1, select("#", ...) do
            parts[#parts+1] = dbg_value(select(index, ...))
        end
        print(table.unpack(parts))
    end
end

local function paint(text, color)
    return "<font color='" .. tostring(color or "#ffffff") .. "'>" .. tostring(text or "") .. "</font>"
end

-- Build a two-column info card matching the Thermostat Controller style.
-- rows = { {icon="⚡", label="Name", value="123 W", vc=optional_color}, ... }
local function build_card(icon, title, rows)
    local W  = config.ui.widthPx
    local cL = config.ui.colLeft
    local cR = W - cL
    local c1 = config.colors.color1
    local c2 = config.colors.color2
    local fs = config.ui.bodyFontSize
    local divider = config.ui.divider or {}
    local parts = {}
    parts[#parts+1] = "<table width=" .. W .. " border=0 style='table-layout:fixed;'>"
    parts[#parts+1] = "<tr><td colspan=2 align=left>" ..
        "<font size='" .. config.ui.titleFontSize .. "'>" ..
        paint("<b>" .. icon .. " " .. title .. "</b>", c1) ..
        "</font></td></tr>"
    for _, row in ipairs(rows) do
        if row.divider == true then
            parts[#parts+1] = "<tr><td colspan=2>" ..
                "<hr width=" .. W .. "px color=" .. tostring(row.color or divider.color or "DarkSeaGreen") ..
                " size=" .. tostring(row.sizePx or divider.sizePx or 4) .. "px />" ..
                "</td></tr>"
        else
            local lbl = paint((row.icon and row.icon .. " " or "") .. tostring(row.label or ""), row.lc or c1)
            local val = paint(tostring(row.value ~= nil and row.value or "-"), row.vc or c2)
            parts[#parts+1] = "<tr>" ..
                "<td width=" .. cL .. " align=left valign=top>" ..
                "<font size='" .. fs .. "'>" .. lbl .. "</font></td>" ..
                "<td width=" .. cR .. " align=right valign=top>" ..
                "<font size='" .. fs .. "'>" .. val .. "</font></td>" ..
                "</tr>"
        end
    end
    parts[#parts+1] = "</table>"
    return table.concat(parts)
end

local function build_divider()
    local d = config.ui.divider
    return "<hr width=" .. config.ui.widthPx .. "px color=" .. d.color .. " size=" .. d.sizePx .. "px />"
end

local function with_top_divider(content)
    return build_divider() .. tostring(content or "")
end

local function format_day_hour_label(ts)
    if ts == nil then return "-" end
    return os.date("%d/%m", ts) .. " 🕐" .. os.date("%H:00", ts)
end

local function round3(value)
    return math.floor((tonumber(value) or 0) * 1000 + 0.5) / 1000
end

local function round4(value)
    return math.floor((tonumber(value) or 0) * 10000 + 0.5) / 10000
end

local function round0(value)
    return math.floor((tonumber(value) or 0) + 0.5)
end

local function calculate_phase_apparent_power(phase_data, current_value)
    local voltage = tonumber(phase_data and phase_data.u)
    local amperage = tonumber(phase_data and phase_data.i)

    if voltage ~= nil and amperage ~= nil and voltage > 0 and amperage >= 0 then
        return round0(voltage * amperage)
    end

    return tonumber(current_value) or 0
end

local function calculate_phase_power_factor_from_children(active_uid, reactive_uid)
    local active_power = tonumber(Child_table[active_uid] and Child_table[active_uid].store and Child_table[active_uid].store.value) or 0
    local reactive_power = tonumber(Child_table[reactive_uid] and Child_table[reactive_uid].store and Child_table[reactive_uid].store.value) or 0
    local apparent_power = math.sqrt((active_power * active_power) + (reactive_power * reactive_power))

    if apparent_power <= 0 then return nil end

    local pf = math.abs(active_power) / apparent_power
    pf = math.max(0, math.min(1, pf))
    return round3(pf)
end

local function register_phase_power_factor_reading(self, phase_key, raw_value)
    local raw_pf = tonumber(raw_value)
    local pf_uid_map = { l1 = "s14", l2 = "s19", l3 = "s24" }
    local pf_uid = pf_uid_map[phase_key]

    if type(self.runtime.phase_power_factor_raw_failures) ~= "table" then
        self.runtime.phase_power_factor_raw_failures = { l1 = 0, l2 = 0, l3 = 0 }
    end

    if type(self.runtime.phase_power_factor_raw_values) ~= "table" then
        self.runtime.phase_power_factor_raw_values = { l1 = nil, l2 = nil, l3 = nil }
    end

    if raw_pf ~= nil and raw_pf ~= 0 then
        self.runtime.phase_power_factor_raw_values[phase_key] = round3(raw_pf)
        self.runtime.phase_power_factor_raw_failures[phase_key] = 0
        self.runtime.phase_power_factor_sources[phase_key] = "raw"
        self.runtime.phase_power_factor_snapshots[phase_key] = nil
        if pf_uid ~= nil then
            Child_table[pf_uid].store.value = round3(raw_pf)
            local child = self.children and self.children[pf_uid]
            if child then
                child:update(Child_table, pf_uid)
            end
        end
        return
    end

    self.runtime.phase_power_factor_raw_values[phase_key] = raw_pf ~= nil and round3(raw_pf) or nil
    self.runtime.phase_power_factor_raw_failures[phase_key] = (tonumber(self.runtime.phase_power_factor_raw_failures[phase_key]) or 0) + 1
end

local function calculate_total_power_factor_from_children()
    local active_total = tonumber(Child_table["s3"] and Child_table["s3"].store and Child_table["s3"].store.value)
    if active_total == nil or active_total == 0 then
        local import_active = tonumber(Child_table["s1"] and Child_table["s1"].store and Child_table["s1"].store.value) or 0
        local export_active = tonumber(Child_table["s2"] and Child_table["s2"].store and Child_table["s2"].store.value) or 0
        active_total = import_active - export_active
    end

    local reactive_import = tonumber(Child_table["s4"] and Child_table["s4"].store and Child_table["s4"].store.value) or 0
    local reactive_export = tonumber(Child_table["s5"] and Child_table["s5"].store and Child_table["s5"].store.value) or 0
    local reactive_total = reactive_import - reactive_export
    local apparent_power = math.sqrt((active_total * active_total) + (reactive_total * reactive_total))

    if apparent_power <= 0 then return nil end

    local pf = math.abs(active_total) / apparent_power
    pf = math.max(0, math.min(1, pf))
    return round3(pf)
end

local function register_total_power_factor_reading(self, raw_value)
    local raw_pf = tonumber(raw_value)

    if raw_pf ~= nil and raw_pf ~= 0 then
        self.runtime.total_power_factor = round3(raw_pf)
        self.runtime.total_power_factor_raw_failures = 0
        Child_table["s41"].store.value = round3(raw_pf)
        local child = self.children and self.children["s41"]
        if child then
            child:update(Child_table, "s41")
        end
        return
    end

    self.runtime.total_power_factor = raw_pf ~= nil and round3(raw_pf) or nil
    self.runtime.total_power_factor_raw_failures = (tonumber(self.runtime.total_power_factor_raw_failures) or 0) + 1
end

local function refresh_total_power_factor_child(self, force)
    local interval = math.max(1, tonumber(config.power_factor_refresh_interval) or 60)
    local now = os.time()
    local last_update_ts = tonumber(self.runtime.total_power_factor_last_update_ts) or 0

    if force ~= true and last_update_ts > 0 and (now - last_update_ts) < interval then
        return
    end

    local raw_pf = tonumber(self.runtime.total_power_factor)
    local failures = tonumber(self.runtime.total_power_factor_raw_failures) or 0
    local fallback_after = math.max(1, tonumber(config.power_factor_fallback_after_fails) or 10)
    local resolved_pf = nil

    if failures >= fallback_after then
        resolved_pf = calculate_total_power_factor_from_children()
    end

    if resolved_pf ~= nil then
        Child_table["s41"].store.value = resolved_pf
    end

    self.runtime.total_power_factor_last_update_ts = now

    local child = self.children and self.children["s41"]
    if child then
        child:update(Child_table, "s41")
    end
end

local function refresh_phase_power_factor_children(self, force)
    local interval = math.max(1, tonumber(config.power_factor_refresh_interval) or 60)
    local now = os.time()
    local last_update_ts = tonumber(self.runtime.phase_power_factor_last_update_ts) or 0

    if force ~= true and last_update_ts > 0 and (now - last_update_ts) < interval then
        return
    end

    local fallback_after = math.max(1, tonumber(config.power_factor_fallback_after_fails) or 10)
    local mappings = {
        { key = "l1", active_uid = "s12", reactive_uid = "s13", apparent_uid = "s42", pf_uid = "s14" },
        { key = "l2", active_uid = "s17", reactive_uid = "s18", apparent_uid = "s43", pf_uid = "s19" },
        { key = "l3", active_uid = "s22", reactive_uid = "s23", apparent_uid = "s44", pf_uid = "s24" },
    }

    for _, item in ipairs(mappings) do
        local raw_pf = tonumber(self.runtime.phase_power_factor_raw_values and self.runtime.phase_power_factor_raw_values[item.key])
        local failures = tonumber(self.runtime.phase_power_factor_raw_failures and self.runtime.phase_power_factor_raw_failures[item.key]) or 0
        local resolved_pf = nil
        local source = "raw"

        if failures >= fallback_after then
            resolved_pf = calculate_phase_power_factor_from_children(item.active_uid, item.reactive_uid)
            source = resolved_pf ~= nil and "calculated" or "raw"
        end

        if resolved_pf ~= nil then
            Child_table[item.pf_uid].store.value = resolved_pf
        end

        self.runtime.phase_power_factor_sources[item.key] = source

        if source == "calculated" then
            self.runtime.phase_power_factor_snapshots[item.key] = {
                active = Child_table[item.active_uid].store.value,
                reactive = Child_table[item.reactive_uid].store.value,
                apparent = Child_table[item.apparent_uid].store.value,
                pf = Child_table[item.pf_uid].store.value,
            }
        else
            self.runtime.phase_power_factor_snapshots[item.key] = nil
        end

        local child = self.children and self.children[item.pf_uid]
        if child then
            child:update(Child_table, item.pf_uid)
        end
    end

    self.runtime.phase_power_factor_last_update_ts = now
end

local function get_hour_start_ts(ts)
    local t = os.date("*t", ts or os.time())
    t.min = 0
    t.sec = 0
    return os.time(t)
end

local function load_hour_history(self)
    if type(self.hour_history_cache) == "table" then
        return self.hour_history_cache
    end

    local history = {}
    local raw = self.store.energy_hour_history_json
    if raw and raw ~= "" then
        local ok, decoded = pcall(json.decode, raw)
        if ok and type(decoded) == "table" then
            for _, entry in ipairs(decoded) do
                if type(entry) == "table" then
                    local ts = tonumber(entry.ts or entry.start_ts or entry[1])
                    local value = tonumber(entry.value or entry.kwh or entry[2])
                    if ts and value then
                        history[#history+1] = {
                            ts = math.floor(ts),
                            value = round3(value),
                            corrected = entry.corrected == true or entry.c == true,
                        }
                    end
                end
            end
        end
    end

    table.sort(history, function(a, b) return a.ts < b.ts end)

    local threshold = tonumber(config.hour_history_ignore_above_kwh)
    if threshold ~= nil and threshold > 0 then
        local repaired = false
        local previous_value = nil

        for _, entry in ipairs(history) do
            local value = tonumber(entry.value) or 0
            if value > threshold then
                entry.value = round3(previous_value or 0)
                entry.corrected = true
                repaired = true
            else
                previous_value = value
            end
        end

        if repaired then
            dbg("Repaired stored hour history spikes")
        end
    end

    while #history > config.hour_history_limit do
        table.remove(history, 1)
    end

    self.hour_history_cache = history
    self.store.energy_hour_history_json = json.encode(history)
    return history
end

local function save_hour_history(self, history)
    while #history > config.hour_history_limit do
        table.remove(history, 1)
    end

    self.hour_history_cache = history
    self.store.energy_hour_history_json = json.encode(history)
end

local function add_hour_history(self, ts, value, corrected)
    if ts == nil or value == nil then return end

    local history = load_hour_history(self)
    local hour_ts = math.floor(tonumber(ts) or 0)
    local rounded_value = round3(value)
    local is_corrected = corrected == true
    local replaced = false

    for i = #history, 1, -1 do
        if tonumber(history[i].ts) == hour_ts then
            history[i].value = rounded_value
            history[i].corrected = is_corrected
            replaced = true
            break
        end
    end

    if not replaced then
        history[#history+1] = { ts = hour_ts, value = rounded_value, corrected = is_corrected }
    end

    table.sort(history, function(a, b) return a.ts < b.ts end)
    save_hour_history(self, history)
end

local function get_hour_history_value(self, ts)
    local hour_ts = math.floor(tonumber(ts) or 0)
    for _, entry in ipairs(load_hour_history(self)) do
        if tonumber(entry.ts) == hour_ts then
            return tonumber(entry.value)
        end
    end
    return nil
end

local function sanitize_hour_history_value(self, ts, value)
    local hourly_value = tonumber(value)
    if hourly_value == nil then return nil, false end

    local threshold = tonumber(config.hour_history_ignore_above_kwh)
    if threshold == nil or threshold <= 0 or hourly_value <= threshold then
        return round3(hourly_value), false
    end

    local fallback_value = get_hour_history_value(self, (tonumber(ts) or 0) - 3600)
    if fallback_value == nil then
        fallback_value = 0
    end

    fallback_value = round3(fallback_value)
    dbg("Ignoring hour history spike", tostring(hourly_value), "->", tostring(fallback_value), "for", os.date("%Y-%m-%d %H:00", tonumber(ts) or os.time()))
    return fallback_value, true
end

local function get_month_start_ts(ts)
    local t = os.date("*t", ts or os.time())
    t.day = 1
    t.hour = 0
    t.min = 0
    t.sec = 0
    return os.time(t)
end

local function get_days_in_month(ts)
    local t = os.date("*t", ts or os.time())
    local next_month = { year = t.year, month = t.month + 1, day = 0, hour = 12, min = 0, sec = 0 }
    return tonumber(os.date("%d", os.time(next_month))) or 31
end

local function decode_json_table(payload)
    if type(payload) == "table" then return payload end
    if type(payload) ~= "string" then
        return nil, "Invalid payload type: " .. type(payload)
    end

    local ok, decoded = pcall(json.decode, payload)
    if not ok or type(decoded) ~= "table" then
        return nil, tostring(decoded)
    end
    return decoded
end

local function create_minmax_state()
    return {
        voltage_min = { l1 = nil, l2 = nil, l3 = nil },
        voltage_min_ts = { l1 = nil, l2 = nil, l3 = nil },
        voltage_max = { l1 = nil, l2 = nil, l3 = nil },
        voltage_max_ts = { l1 = nil, l2 = nil, l3 = nil },
        amp_max = { l1 = nil, l2 = nil, l3 = nil },
        amp_max_ts = { l1 = nil, l2 = nil, l3 = nil },
        watt_import_peak = nil,
        watt_import_peak_ts = nil,
        watt_export_peak = nil,
        watt_export_peak_ts = nil,
        hour_import_peak = nil,
        hour_import_peak_ts = nil,
        hour_export_peak = nil,
        hour_export_peak_ts = nil,
    }
end

local function load_minmax_state(self)
    if type(self.runtime.minmax_state) == "table" then
        return self.runtime.minmax_state
    end

    local state = create_minmax_state()
    local raw = self.store.minmax_state_json
    if raw and raw ~= "" then
        local decoded, err = decode_json_table(raw)
        if decoded then
            local voltage_min = type(decoded.voltage_min) == "table" and decoded.voltage_min or {}
            local voltage_min_ts = type(decoded.voltage_min_ts) == "table" and decoded.voltage_min_ts or {}
            local voltage_max = type(decoded.voltage_max) == "table" and decoded.voltage_max or {}
            local voltage_max_ts = type(decoded.voltage_max_ts) == "table" and decoded.voltage_max_ts or {}
            local amp_max = type(decoded.amp_max) == "table" and decoded.amp_max or {}
            local amp_max_ts = type(decoded.amp_max_ts) == "table" and decoded.amp_max_ts or {}

            state.voltage_min.l1 = tonumber(voltage_min.l1)
            state.voltage_min.l2 = tonumber(voltage_min.l2)
            state.voltage_min.l3 = tonumber(voltage_min.l3)
            state.voltage_min_ts.l1 = tonumber(voltage_min_ts.l1)
            state.voltage_min_ts.l2 = tonumber(voltage_min_ts.l2)
            state.voltage_min_ts.l3 = tonumber(voltage_min_ts.l3)
            state.voltage_max.l1 = tonumber(voltage_max.l1)
            state.voltage_max.l2 = tonumber(voltage_max.l2)
            state.voltage_max.l3 = tonumber(voltage_max.l3)
            state.voltage_max_ts.l1 = tonumber(voltage_max_ts.l1)
            state.voltage_max_ts.l2 = tonumber(voltage_max_ts.l2)
            state.voltage_max_ts.l3 = tonumber(voltage_max_ts.l3)
            state.amp_max.l1 = tonumber(amp_max.l1)
            state.amp_max.l2 = tonumber(amp_max.l2)
            state.amp_max.l3 = tonumber(amp_max.l3)
            state.amp_max_ts.l1 = tonumber(amp_max_ts.l1)
            state.amp_max_ts.l2 = tonumber(amp_max_ts.l2)
            state.amp_max_ts.l3 = tonumber(amp_max_ts.l3)
            state.watt_import_peak = tonumber(decoded.watt_import_peak)
            state.watt_import_peak_ts = tonumber(decoded.watt_import_peak_ts)
            state.watt_export_peak = tonumber(decoded.watt_export_peak)
            state.watt_export_peak_ts = tonumber(decoded.watt_export_peak_ts)
            state.hour_import_peak = tonumber(decoded.hour_import_peak)
            state.hour_import_peak_ts = tonumber(decoded.hour_import_peak_ts)
            state.hour_export_peak = tonumber(decoded.hour_export_peak)
            state.hour_export_peak_ts = tonumber(decoded.hour_export_peak_ts)
        else
            dbg("load_minmax_state decode failed", err)
        end
    end

    self.runtime.minmax_state = state
    return state
end

local function save_minmax_state(self, state)
    self.runtime.minmax_state = state
    self.store.minmax_state_json = json.encode(state)
end

local function update_minmax_state(self)
    local state = load_minmax_state(self)
    local changed = false
    local now_ts = os.time()

    local function update_min(bucket, bucket_ts, key, value)
        local numeric = tonumber(value)
        if numeric == nil or numeric <= 0 then return end
        local current = tonumber(bucket[key])
        if current == nil or numeric < current then
            bucket[key] = numeric
            bucket_ts[key] = now_ts
            changed = true
        end
    end

    local function update_max(bucket, bucket_ts, key, value)
        local numeric = tonumber(value)
        if numeric == nil or numeric <= 0 then return end
        local current = tonumber(bucket[key])
        if current == nil or numeric > current then
            bucket[key] = numeric
            bucket_ts[key] = now_ts
            changed = true
        end
    end

    local function update_scalar_max(value_key, ts_key, value)
        local numeric = tonumber(value)
        if numeric == nil or numeric <= 0 then return end
        local current = tonumber(state[value_key])
        if current == nil or numeric > current then
            state[value_key] = numeric
            state[ts_key] = now_ts
            changed = true
        end
    end

    local function child_value(uid)
        return Child_table[uid] and Child_table[uid].store and Child_table[uid].store.value
    end

    update_min(state.voltage_min, state.voltage_min_ts, "l1", child_value("s10"))
    update_min(state.voltage_min, state.voltage_min_ts, "l2", child_value("s15"))
    update_min(state.voltage_min, state.voltage_min_ts, "l3", child_value("s20"))
    update_max(state.voltage_max, state.voltage_max_ts, "l1", child_value("s10"))
    update_max(state.voltage_max, state.voltage_max_ts, "l2", child_value("s15"))
    update_max(state.voltage_max, state.voltage_max_ts, "l3", child_value("s20"))
    update_max(state.amp_max, state.amp_max_ts, "l1", child_value("s11"))
    update_max(state.amp_max, state.amp_max_ts, "l2", child_value("s16"))
    update_max(state.amp_max, state.amp_max_ts, "l3", child_value("s21"))
    update_scalar_max("watt_import_peak", "watt_import_peak_ts", child_value("s1"))
    update_scalar_max("watt_export_peak", "watt_export_peak_ts", child_value("s2"))
    update_scalar_max("hour_import_peak", "hour_import_peak_ts", child_value("s25"))
    update_scalar_max("hour_export_peak", "hour_export_peak_ts", child_value("s36"))

    if changed then
        save_minmax_state(self, state)
    end

    return state
end

local function load_month_history(self)
    if type(self.month_history_cache) == "table" then
        return self.month_history_cache
    end

    local history = {}
    local raw = self.store.month_day_history_json
    if raw and raw ~= "" then
        local decoded, err = decode_json_table(raw)
        if decoded then
            for _, entry in ipairs(decoded) do
                if type(entry) == "table" then
                    local ts = tonumber(entry.ts or entry.day_ts or entry[1])
                    local value = tonumber(entry.value or entry.kwh or entry[2])
                    if ts and value then
                        history[#history+1] = {
                            ts = math.floor(ts),
                            value = round3(value),
                        }
                    end
                end
            end
        else
            dbg("load_month_history decode failed", err)
        end
    end

    table.sort(history, function(a, b) return a.ts < b.ts end)
    while #history > config.month_history_limit do
        table.remove(history, 1)
    end

    self.month_history_cache = history
    self.store.month_day_history_json = json.encode(history)
    return history
end

local function save_month_history(self, history)
    while #history > config.month_history_limit do
        table.remove(history, 1)
    end

    self.month_history_cache = history
    self.store.month_day_history_json = json.encode(history)
end

local function add_month_history_entry(self, ts, value)
    if ts == nil or value == nil then return end

    local history = load_month_history(self)
    local day_ts = math.floor(tonumber(ts) or 0)
    local rounded_value = round3(value)
    local replaced = false

    for i = #history, 1, -1 do
        if tonumber(history[i].ts) == day_ts then
            history[i].value = rounded_value
            replaced = true
            break
        end
    end

    if not replaced then
        history[#history+1] = {
            ts = day_ts,
            value = rounded_value,
        }
    end

    table.sort(history, function(a, b) return a.ts < b.ts end)
    save_month_history(self, history)
end

local function calculate_month_total_from_history(self, month_ts)
    local month_start_ts = get_month_start_ts(month_ts)
    local month_key = os.date("%Y-%m", month_start_ts)
    local total = 0

    for _, entry in ipairs(load_month_history(self)) do
        local entry_ts = tonumber(entry.ts)
        if entry_ts ~= nil and os.date("%Y-%m", entry_ts) == month_key then
            total = total + (tonumber(entry.value) or 0)
        end
    end

    return round3(total)
end

local function load_month_totals_history(self)
    if type(self.month_totals_history_cache) == "table" then
        return self.month_totals_history_cache
    end

    local history = {}
    local raw = self.store.month_totals_history_json
    if raw and raw ~= "" then
        local decoded, err = decode_json_table(raw)
        if decoded then
            for _, entry in ipairs(decoded) do
                if type(entry) == "table" then
                    local ts = tonumber(entry.ts or entry.month_ts or entry[1])
                    local value = tonumber(entry.value or entry.kwh or entry[2])
                    if ts and value then
                        history[#history+1] = {
                            ts = math.floor(ts),
                            value = round3(value),
                        }
                    end
                end
            end
        else
            dbg("load_month_totals_history decode failed", err)
        end
    end

    table.sort(history, function(a, b) return a.ts < b.ts end)
    while #history > (tonumber(config.month_totals_history_limit) or 60) do
        table.remove(history, 1)
    end

    self.month_totals_history_cache = history
    self.store.month_totals_history_json = json.encode(history)
    return history
end

local function save_month_totals_history(self, history)
    local limit = tonumber(config.month_totals_history_limit) or 60
    while #history > limit do
        table.remove(history, 1)
    end

    self.month_totals_history_cache = history
    self.store.month_totals_history_json = json.encode(history)
end

local function parse_monthplot_seed_timestamp(entry)
    if type(entry) ~= "table" then return nil end

    local ts = tonumber(entry.ts or entry.month_ts or entry[1])
    if ts ~= nil then
        return get_month_start_ts(ts)
    end

    local month_key = tostring(entry.month or entry.ym or "")
    local year, month = month_key:match("^(%d%d%d%d)%-(%d%d)$")
    if year == nil then
        month, year = month_key:match("^(%d%d)/(%d%d%d%d)$")
    end
    if year == nil or month == nil then
        return nil
    end

    return os.time({
        year = tonumber(year),
        month = tonumber(month),
        day = 1,
        hour = 0,
        min = 0,
        sec = 0,
    })
end

local function parse_month_key_timestamp(month_key)
    local year, month = tostring(month_key or ""):match("^(%d%d%d%d)%-(%d%d)$")
    if year == nil or month == nil then return nil end

    return os.time({
        year = tonumber(year),
        month = tonumber(month),
        day = 1,
        hour = 0,
        min = 0,
        sec = 0,
    })
end

local function import_monthplot_seed(self)
    local seed = amsreader_monthplot_seed
    if type(seed) ~= "table" and type(_G) == "table" then
        seed = rawget(_G, "amsreader_monthplot_seed")
    end
    if type(seed) ~= "table" or #seed == 0 then
        dbg("Monthplot seed missing or empty")
        return
    end

    local history = load_month_totals_history(self)
    local history_is_empty = #history == 0
    local changed = false

    for _, entry in ipairs(seed) do
        local ts = parse_monthplot_seed_timestamp(entry)
        local value = tonumber(type(entry) == "table" and (entry.value or entry.kwh or entry.total or entry[2]) or nil)

        if ts ~= nil and value ~= nil then
            local exists = false
            for _, existing in ipairs(history) do
                if tonumber(existing.ts) == ts then
                    exists = true
                    break
                end
            end

            if not exists then
                history[#history+1] = {
                    ts = math.floor(ts),
                    value = round3(value),
                }
                changed = true
            end
        end
    end

    if history_is_empty and changed then
        dbg("Seeding month totals history from amsreader_monthplot_seed", #history)
    end

    if changed then
        table.sort(history, function(a, b) return a.ts < b.ts end)
        save_month_totals_history(self, history)
    end
end

local function add_month_total_history(self, ts, value)
    if ts == nil or value == nil then return end

    local history = load_month_totals_history(self)
    local month_ts = get_month_start_ts(ts)
    local rounded_value = round3(value)
    local replaced = false

    for i = #history, 1, -1 do
        if tonumber(history[i].ts) == month_ts then
            history[i].value = rounded_value
            replaced = true
            break
        end
    end

    if not replaced then
        history[#history+1] = { ts = month_ts, value = rounded_value }
    end

    table.sort(history, function(a, b) return a.ts < b.ts end)
    save_month_totals_history(self, history)
end

local function get_month_totals_history_for_display(self)
    local history = load_month_totals_history(self)
    local display_history = {}

    for _, entry in ipairs(history) do
        display_history[#display_history+1] = {
            ts = tonumber(entry.ts),
            value = round3(entry.value),
        }
    end

    local live_month_key = tostring(self.store.live_month_total_key or "")
    local live_month_value = tonumber(self.store.live_month_total_value)
    local live_month_ts = parse_month_key_timestamp(live_month_key)

    if live_month_ts ~= nil and live_month_value ~= nil then
        local rounded_live_value = round3(live_month_value)
        local replaced = false

        for _, entry in ipairs(display_history) do
            if tonumber(entry.ts) == live_month_ts then
                entry.value = rounded_live_value
                replaced = true
                break
            end
        end

        if not replaced then
            display_history[#display_history+1] = {
                ts = live_month_ts,
                value = rounded_live_value,
            }
        end

        table.sort(display_history, function(a, b)
            return (tonumber(a.ts) or 0) < (tonumber(b.ts) or 0)
        end)
    end

    return display_history
end

local function load_tariff_state(self)
    if type(self.tariff_state_cache) == "table" then
        return self.tariff_state_cache
    end

    local tariff = {
        thresholds = {},
        peaks = {},
        current_threshold = nil,
        month_avg = nil,
        last_sync = "",
    }

    local raw = self.store.tariff_state_json
    if raw and raw ~= "" then
        local decoded, err = decode_json_table(raw)
        if decoded then
            if type(decoded.thresholds) == "table" then
                for _, threshold in ipairs(decoded.thresholds) do
                    local value = tonumber(threshold)
                    if value ~= nil then
                        tariff.thresholds[#tariff.thresholds+1] = value
                    end
                end
            end

            if type(decoded.peaks) == "table" then
                for _, entry in ipairs(decoded.peaks) do
                    if type(entry) == "table" then
                        local day = tonumber(entry.day or entry.d or entry[1])
                        local value = tonumber(entry.value or entry.v or entry[2])
                        if day ~= nil and value ~= nil then
                            tariff.peaks[#tariff.peaks+1] = {
                                day = math.floor(day),
                                value = round3(value),
                            }
                        end
                    end
                end
            end

            tariff.current_threshold = tonumber(decoded.current_threshold or decoded.c)

            local month_avg = tonumber(decoded.month_avg or decoded.m)
            tariff.month_avg = month_avg ~= nil and round3(month_avg) or nil
            tariff.last_sync = tostring(decoded.last_sync or "")
        else
            dbg("load_tariff_state decode failed", err)
        end
    end

    table.sort(tariff.peaks, function(a, b)
        if a.value == b.value then
            return a.day < b.day
        end
        return a.value > b.value
    end)

    self.tariff_state_cache = tariff
    self.store.tariff_state_json = json.encode(tariff)
    return tariff
end

local function save_tariff_state(self, tariff)
    self.tariff_state_cache = tariff
    self.store.tariff_state_json = json.encode(tariff)
end

local function apply_tariff_state(self, tariff)
    tariff = tariff or load_tariff_state(self)
    local peaks = tariff.peaks or {}

    Child_table["s29"].store.value = peaks[1] and round3(peaks[1].value) or 0
    Child_table["s30"].store.value = peaks[2] and round3(peaks[2].value) or 0
    Child_table["s31"].store.value = peaks[3] and round3(peaks[3].value) or 0
    Child_table["s32"].store.value = tariff.month_avg ~= nil and round3(tariff.month_avg) or 0

    self.store.tariff_next_threshold = tariff.current_threshold
    self.store.tariff_month_avg = tariff.month_avg
end

local function update_tariff_children(self)
    for _, uid in ipairs({"s29", "s30", "s31", "s32"}) do
        local child = self.children and self.children[uid]
        if child then
            child:update(Child_table, uid)
        end
    end
end

local function normalize_energyaccounting_period(raw)
    raw = type(raw) == "table" and raw or {}
    return {
        u = tonumber(raw.u),
        c = tonumber(raw.c),
        p = tonumber(raw.p),
        i = tonumber(raw.i),
    }
end

local function load_energyaccounting_state(self)
    if type(self.energyaccounting_state_cache) == "table" then
        return self.energyaccounting_state_cache
    end

    local state = {
        x = nil,
        peaks = {},
        threshold = nil,
        h = normalize_energyaccounting_period(nil),
        d = normalize_energyaccounting_period(nil),
        m = normalize_energyaccounting_period(nil),
        last_sync = "",
    }

    local raw = self.store.energyaccounting_state_json
    if raw and raw ~= "" then
        local decoded, err = decode_json_table(raw)
        if decoded then
            state.x = tonumber(decoded.x or decoded.max_average)
            state.threshold = tonumber(decoded.threshold or decoded.t)
            state.h = normalize_energyaccounting_period(decoded.h)
            state.d = normalize_energyaccounting_period(decoded.d)
            state.m = normalize_energyaccounting_period(decoded.m)
            state.last_sync = tostring(decoded.last_sync or "")

            local peaks = decoded.peaks or decoded.p
            if type(peaks) == "table" then
                for _, peak in ipairs(peaks) do
                    local value = tonumber(peak)
                    if value ~= nil then
                        state.peaks[#state.peaks+1] = round3(value)
                    end
                end
            end
        else
            dbg("load_energyaccounting_state decode failed", err)
        end
    end

    self.energyaccounting_state_cache = state
    self.store.energyaccounting_state_json = json.encode(state)
    return state
end

local function save_energyaccounting_state(self, state)
    self.energyaccounting_state_cache = state
    self.store.energyaccounting_state_json = json.encode(state)
end

local function sync_energyaccounting_from_payload(self, payload)
    local ea, err = decode_json_table(payload)
    if not ea then return false, err end

    local state = {
        x = tonumber(ea.x),
        peaks = {},
        threshold = tonumber(ea.t),
        h = normalize_energyaccounting_period(ea.h),
        d = normalize_energyaccounting_period(ea.d),
        m = normalize_energyaccounting_period(ea.m),
        last_sync = os.date("%Y-%m-%d %H:%M:%S"),
    }

    if type(ea.p) == "table" then
        for _, peak in ipairs(ea.p) do
            local value = tonumber(peak)
            if value ~= nil then
                state.peaks[#state.peaks+1] = round3(value)
            end
        end
    end

    local current_month_ts = get_month_start_ts()
    local current_month_key = os.date("%Y-%m", current_month_ts)
    local previous_month_key = tostring(self.store.live_month_total_key or "")
    local previous_month_value = tonumber(self.store.live_month_total_value)

    if previous_month_key ~= "" and previous_month_key ~= current_month_key and previous_month_value ~= nil then
        local previous_month_ts = parse_month_key_timestamp(previous_month_key)
        if previous_month_ts ~= nil then
            add_month_total_history(self, previous_month_ts, previous_month_value)
            dbg("Locked final live month total into history", previous_month_key, previous_month_value)
        end
    end

    if tonumber(state.m.u) ~= nil then
        self.store.live_month_total_key = current_month_key
        self.store.live_month_total_value = round3(state.m.u)
        self.store.live_month_total_last_sync = state.last_sync
    end

    save_energyaccounting_state(self, state)
    self.store.energyaccounting_last_sync = state.last_sync
    return true
end

local function load_energyprice_schedule(self)
    if type(self.energyprice_schedule_cache) == "table" then
        return self.energyprice_schedule_cache
    end

    local schedule = {
        currency = "",
        source = "",
        base_ts = 0,
        entries = {},
    }

    local raw = self.store.energyprice_schedule_json
    if raw and raw ~= "" then
        local decoded, err = decode_json_table(raw)
        if decoded then
            schedule.currency = tostring(decoded.currency or "")
            schedule.source = tostring(decoded.source or "")
            schedule.base_ts = math.floor(tonumber(decoded.base_ts) or 0)

            if type(decoded.entries) == "table" then
                for _, entry in ipairs(decoded.entries) do
                    if type(entry) == "table" then
                        schedule.entries[#schedule.entries+1] = {
                            offset = math.floor(tonumber(entry.offset) or #schedule.entries),
                            ts = math.floor(tonumber(entry.ts) or 0),
                            known = entry.known == true,
                            value = entry.known == true and round4(entry.value) or nil,
                            corrected = entry.corrected == true,
                        }
                    end
                end
            end
        else
            dbg("load_energyprice_schedule decode failed", err)
        end
    end

    self.energyprice_schedule_cache = schedule
    self.store.energyprice_schedule_json = json.encode(schedule)
    return schedule
end

local function save_energyprice_schedule(self, schedule)
    self.energyprice_schedule_cache = schedule
    self.store.energyprice_schedule_json = json.encode(schedule)
end

local function get_accounting_currency(self)
    local schedule = load_energyprice_schedule(self)
    local currency = tostring((schedule and schedule.currency) or self.store.ams_configuration_currency or "")
    if currency == "" then currency = "kr" end
    return currency
end

local function update_child_from_table(self, uid)
    local child = self.children and self.children[uid]
    if child then
        child:update(Child_table, uid)
    end
end

local function update_hourly_accounting_children(self, state)
    state = state or load_energyaccounting_state(self)
    local hour = type(state.h) == "table" and state.h or {}
    local currency = get_accounting_currency(self)

    Child_table["s25"].store.value = round3(hour.u or 0)
    Child_table["s35"].store.value = round3(hour.c or 0)
    Child_table["s35"].store.unit = currency
    Child_table["s36"].store.value = round3(hour.p or 0)
    Child_table["s37"].store.value = round3(hour.i or 0)
    Child_table["s37"].store.unit = currency

    for _, uid in ipairs({"s25", "s35", "s36", "s37"}) do
        update_child_from_table(self, uid)
    end
end

local function update_daily_accounting_children(self, state)
    state = state or load_energyaccounting_state(self)
    local day = type(state.d) == "table" and state.d or {}
    local currency = get_accounting_currency(self)

    Child_table["s27"].store.value = round3(day.u or 0)
    Child_table["s38"].store.value = round3(day.c or 0)
    Child_table["s38"].store.unit = currency
    Child_table["s39"].store.value = round3(day.p or 0)
    Child_table["s40"].store.value = round3(day.i or 0)
    Child_table["s40"].store.unit = currency

    for _, uid in ipairs({"s27", "s38", "s39", "s40"}) do
        update_child_from_table(self, uid)
    end
end

local function update_monthly_accounting_children(self, state)
    state = state or load_energyaccounting_state(self)
    local month = type(state.m) == "table" and state.m or {}
    local currency = get_accounting_currency(self)

    Child_table["s45"].store.value = round3(month.u or 0)
    Child_table["s46"].store.value = round3(month.c or 0)
    Child_table["s46"].store.unit = currency
    Child_table["s47"].store.value = round3(month.p or 0)
    Child_table["s48"].store.value = round3(month.i or 0)
    Child_table["s48"].store.unit = currency

    for _, uid in ipairs({"s45", "s46", "s47", "s48"}) do
        update_child_from_table(self, uid)
    end
end

local function update_last_hour_import_child(self)
    local history = load_hour_history(self)
    local last_entry = history[#history]

    Child_table["s26"].store.value = last_entry and round3(last_entry.value) or 0
    update_child_from_table(self, "s26")
end

local function update_yesterday_import_child(self)
    local now_t = os.date("*t")
    local yesterday_ts = os.time({
        year = now_t.year,
        month = now_t.month,
        day = now_t.day - 1,
        hour = 0,
        min = 0,
        sec = 0,
    })
    local yesterday_value = 0
    local month_history = load_month_history(self)

    for _, entry in ipairs(month_history) do
        if tonumber(entry.ts) == yesterday_ts then
            yesterday_value = round3(entry.value)
            break
        end
    end

    Child_table["s28"].store.value = yesterday_value
    update_child_from_table(self, "s28")
end

local function sync_energyprice_from_payload(self, payload, base_ts)
    local energyprice, err = decode_json_table(payload)
    if not energyprice then return false, err end

    local current_hour_ts = get_hour_start_ts(base_ts or os.time())
    local previous_schedule = load_energyprice_schedule(self)
    local previous_by_ts = {}
    for _, entry in ipairs(previous_schedule.entries or {}) do
        local entry_ts = tonumber(entry.ts)
        if entry_ts ~= nil and entry.known == true and entry.value ~= nil then
            previous_by_ts[entry_ts] = round4(entry.value)
        end
    end

    local schedule = {
        currency = tostring(energyprice.currency or ""),
        source = tostring(energyprice.source or ""),
        base_ts = current_hour_ts,
        entries = {},
    }

    local seen_keys = 0
    local resolved_keys = 0
    local reused_previous_values = 0
    local missing_zero_values = 0
    for offset = 0, 35 do
        local key = string.format("%02d", offset)
        if energyprice[key] ~= nil then
            seen_keys = seen_keys + 1
        end

        local entry_ts = current_hour_ts + (offset * 3600)
        local price = tonumber(energyprice[key])
        local known = false
        local value = nil
        local corrected = false

        if price ~= nil and price ~= 0 then
            known = true
            value = round4(price)
            resolved_keys = resolved_keys + 1
        elseif price == 0 then
            local previous_value = previous_by_ts[entry_ts]
            if previous_value ~= nil then
                known = true
                value = previous_value
                corrected = true
                reused_previous_values = reused_previous_values + 1
            else
                missing_zero_values = missing_zero_values + 1
            end
        end

        schedule.entries[#schedule.entries+1] = {
            offset = offset,
            ts = entry_ts,
            known = known,
            value = value,
            corrected = corrected,
        }
    end

    if seen_keys == 0 then
        return false, "No energyprice hourly values found"
    end

    if resolved_keys == 0 and reused_previous_values == 0 then
        return false, "Energy prices missing (all values were 0 or unavailable)"
    end

    save_energyprice_schedule(self, schedule)
    self.store.energyprice_last_sync = os.date("%Y-%m-%d %H:%M:%S")
    self.store.energyprice_last_sync_hour_ts = current_hour_ts
    return true, nil, {
        reused_previous_values = reused_previous_values,
        missing_zero_values = missing_zero_values,
    }
end

local function sync_sysinfo_from_payload(self, payload)
    local sysinfo, err = decode_json_table(payload)
    if not sysinfo then return false, err end

    local net = type(sysinfo.net) == "table" and sysinfo.net or {}
    local upgrade = type(sysinfo.upgrade) == "table" and sysinfo.upgrade or {}
    local meter = type(sysinfo.meter) == "table" and sysinfo.meter or {}

    self.store.ams_sysinfo_version = sysinfo.version
    self.store.ams_sysinfo_hostname = sysinfo.hostname
    self.store.ams_sysinfo_device_ip = net.ip
    self.store.ams_sysinfo_mac = sysinfo.mac
    self.store.ams_sysinfo_chip = sysinfo.chip
    self.store.ams_sysinfo_cpu = sysinfo.cpu
    self.store.ams_sysinfo_booting = sysinfo.booting == true
    self.store.ams_sysinfo_upgrading = sysinfo.upgrading == true
    self.store.ams_sysinfo_upgrade_from = upgrade.f
    self.store.ams_sysinfo_upgrade_to = upgrade.t
    self.store.ams_sysinfo_security = tonumber(sysinfo.security)
    self.store.ams_sysinfo_meter_mfg = meter.mfg
    self.store.ams_sysinfo_meter_model = meter.model
    self.store.ams_sysinfo_meter_id = meter.id
    self.store.ams_sysinfo_last_sync = os.date("%Y-%m-%d %H:%M:%S")
    self.store.ams_sysinfo_last_sync_ts = os.time()
    return true
end

local function sync_configuration_from_payload(self, payload)
    local cfg, err = decode_json_table(payload)
    if not cfg then return false, err end

    local meter = type(cfg.m) == "table" and cfg.m or {}
    local multipliers = type(meter.m) == "table" and meter.m or {}
    local price = type(cfg.p) == "table" and cfg.p or {}
    local energy_multiplier = tonumber(multipliers.c)
    if energy_multiplier == nil then
        energy_multiplier = tonumber(multipliers.e)
    end

    self.store.ams_configuration_main_fuse_size = tonumber(meter.f)
    self.store.ams_configuration_distribution_system = tonumber(meter.d)
    self.store.ams_multiplier_ampere = tonumber(multipliers.a)
    self.store.ams_multiplier_voltage = tonumber(multipliers.v)
    self.store.ams_multiplier_energy = energy_multiplier
    self.store.ams_multiplier_watt = tonumber(multipliers.w)
    self.store.ams_multiplier_c_raw = nil
    self.store.ams_price_region_code = price.r
    self.store.ams_configuration_currency = price.c
    self.store.ams_price_interval_minutes = tonumber(price.m)
    self.store.ams_configuration_last_sync = os.date("%Y-%m-%d %H:%M:%S")
    self.store.ams_configuration_last_sync_ts = os.time()

    if self.runtime.ams_main_fuse_size == nil and self.store.ams_configuration_main_fuse_size ~= nil then
        self.runtime.ams_main_fuse_size = self.store.ams_configuration_main_fuse_size
    end
    if self.runtime.ams_distribution_system == nil and self.store.ams_configuration_distribution_system ~= nil then
        self.runtime.ams_distribution_system = self.store.ams_configuration_distribution_system
    end

    return true
end

local function sync_hour_history_from_dayplot(self, payload, target_hour_ts)
    local dayplot, err = decode_json_table(payload)
    if not dayplot then return false, err end

    target_hour_ts = math.floor(tonumber(target_hour_ts) or (get_hour_start_ts() - 3600))
    local last_synced_hour_ts = tonumber(self.store.dayplot_last_synced_hour_ts)
    local first_hour_ts

    if last_synced_hour_ts ~= nil then
        first_hour_ts = last_synced_hour_ts + 3600
    else
        -- Initial seed: use the rolling 24h window provided by /dayplot.json.
        first_hour_ts = target_hour_ts - (23 * 3600)
    end

    if first_hour_ts > target_hour_ts then
        first_hour_ts = target_hour_ts
    end
    if target_hour_ts - first_hour_ts > (23 * 3600) then
        first_hour_ts = target_hour_ts - (23 * 3600)
    end

    local updates = 0
    for hour_ts = first_hour_ts, target_hour_ts, 3600 do
        local utc_hour = tonumber(os.date("!%H", hour_ts)) or 0
        local import_key = string.format("i%02d", utc_hour)
        local import_val = tonumber(dayplot[import_key])
        if import_val ~= nil and import_val ~= 0 then
            local sanitized_value, corrected = sanitize_hour_history_value(self, hour_ts, import_val)
            add_hour_history(self, hour_ts, sanitized_value, corrected)
            updates = updates + 1
        end
    end

    if updates == 0 then
        return false, "No non-zero dayplot import values found"
    end

    self.store.dayplot_last_synced_hour_ts = target_hour_ts
    self.store.dayplot_last_sync = os.date("%Y-%m-%d %H:%M:%S")
    return true
end

local function sync_month_history_from_monthplot(self, payload, month_ts)
    local monthplot, err = decode_json_table(payload)
    if not monthplot then return false, err end

    local month_start_ts = get_month_start_ts(month_ts)
    local month_t = os.date("*t", month_start_ts)
    local month_days = get_days_in_month(month_start_ts)
    local updates = 0

    for day = 1, month_days do
        local import_key = string.format("i%02d", day)
        local import_val = tonumber(monthplot[import_key])
        if import_val ~= nil and import_val ~= 0 then
            local day_ts = os.time({
                year = month_t.year,
                month = month_t.month,
                day = day,
                hour = 0,
                min = 0,
                sec = 0,
            })
            add_month_history_entry(self, day_ts, import_val)
            updates = updates + 1
        end
    end

    if updates == 0 then
        return false, "No non-zero monthplot import values found"
    end

    local total = calculate_month_total_from_history(self, month_start_ts)
    add_month_total_history(self, month_start_ts, total)
    self.store.monthplot_month_key = os.date("%Y-%m", month_start_ts)
    self.store.monthplot_last_sync = os.date("%Y-%m-%d %H:%M:%S")
    self.store.monthplot_last_sync_hour_ts = get_hour_start_ts()
    return true
end

local function sync_tariff_from_payload(self, payload, base_ts)
    local tariff_payload, err = decode_json_table(payload)
    if not tariff_payload then return false, err end

    local current_hour_ts = get_hour_start_ts(base_ts or os.time())
    local tariff = {
        thresholds = {},
        peaks = {},
        current_threshold = tonumber(tariff_payload.c),
        month_avg = nil,
        last_sync = os.date("%Y-%m-%d %H:%M:%S"),
    }

    if type(tariff_payload.t) == "table" then
        for _, threshold in ipairs(tariff_payload.t) do
            local value = tonumber(threshold)
            if value ~= nil then
                tariff.thresholds[#tariff.thresholds+1] = value
            end
        end
    end

    if type(tariff_payload.p) == "table" then
        for _, entry in ipairs(tariff_payload.p) do
            if type(entry) == "table" then
                local day = tonumber(entry.d or entry.day)
                local value = tonumber(entry.v or entry.value)
                if day ~= nil and value ~= nil then
                    tariff.peaks[#tariff.peaks+1] = {
                        day = math.floor(day),
                        value = round3(value),
                    }
                end
            end
        end
    end

    table.sort(tariff.peaks, function(a, b)
        if a.value == b.value then
            return a.day < b.day
        end
        return a.value > b.value
    end)

    local month_avg = tonumber(tariff_payload.m)
    tariff.month_avg = month_avg ~= nil and round3(month_avg) or nil

    if #tariff.peaks == 0 and tariff.current_threshold == nil and tariff.month_avg == nil then
        return false, "No tariff values found"
    end

    save_tariff_state(self, tariff)
    apply_tariff_state(self, tariff)
    self.store.tariff_last_sync = tariff.last_sync
    self.store.tariff_last_sync_hour_ts = current_hour_ts
    return true
end

local function maybe_sync_dayplot(self, force)
    local current_hour_ts = get_hour_start_ts()
    local target_hour_ts = current_hour_ts - 3600
    if target_hour_ts < 0 then return end

    local last_synced_hour_ts = tonumber(self.store.dayplot_last_synced_hour_ts)
    if force == true or last_synced_hour_ts ~= target_hour_ts then
        Http_get_dayplot(target_hour_ts)
    end
end

local function maybe_sync_monthplot(self, force)
    local current_hour_ts = get_hour_start_ts()
    local last_synced_hour_ts = tonumber(self.store.monthplot_last_sync_hour_ts)

    if force == true or last_synced_hour_ts ~= current_hour_ts then
        Http_get_monthplot(current_hour_ts)
    end
end

local function maybe_sync_energyprice(self, force)
    local current_hour_ts = get_hour_start_ts()
    local last_synced_hour_ts = tonumber(self.store.energyprice_last_sync_hour_ts)

    if force == true or last_synced_hour_ts ~= current_hour_ts then
        Http_get_energyprice(current_hour_ts)
    end
end

local function maybe_sync_tariff(self, force)
    local current_hour_ts = get_hour_start_ts()
    local last_synced_hour_ts = tonumber(self.store.tariff_last_sync_hour_ts)

    if force == true or last_synced_hour_ts ~= current_hour_ts then
        Http_get_tariff(current_hour_ts)
    end
end

local function maybe_sync_sysinfo(self, force)
    if self.sysinfo_request_inflight == true then return end

    local now = os.time()
    local refresh_interval = tonumber(config.sysinfo_refresh_interval) or (60 * 60)
    local last_sync_ts = tonumber(self.store.ams_sysinfo_last_sync_ts) or 0

    if force == true or last_sync_ts == 0 or (now - last_sync_ts) >= refresh_interval then
        Http_get_sysinfo()
    end
end

local function maybe_sync_configuration(self, force)
    if self.configuration_request_inflight == true then return end

    local now = os.time()
    local refresh_interval = tonumber(config.configuration_refresh_interval) or (60 * 60)
    local last_sync_ts = tonumber(self.store.ams_configuration_last_sync_ts) or 0

    if force == true or last_sync_ts == 0 or (now - last_sync_ts) >= refresh_interval then
        Http_get_configuration()
    end
end

local function schedule_hourly_sync(self, name, offset_seconds, callback)
    local offset = math.max(0, math.min(3599, tonumber(offset_seconds) or 0))

    local function arm()
        local now = os.time()
        local next_run_ts = get_hour_start_ts(now) + offset
        if next_run_ts <= now then
            next_run_ts = next_run_ts + 3600
        end

        local delay_ms = math.max(1000, (next_run_ts - now) * 1000)
        dbg("Scheduling", name, "for", os.date("%Y-%m-%d %H:%M:%S", next_run_ts))

        hub.setTimeout(delay_ms, function()
            callback()
            arm()
        end)
    end

    arm()
end

local function start_hourly_sync_schedule(self)
    if self.hourly_sync_schedule_started == true then return end
    self.hourly_sync_schedule_started = true

    local offsets = config.hourly_sync_offsets or {}

    schedule_hourly_sync(self, "energyprice", offsets.energyprice, function()
        maybe_sync_energyprice(self, false)
    end)
    schedule_hourly_sync(self, "dayplot", offsets.dayplot, function()
        maybe_sync_dayplot(self, false)
    end)
    schedule_hourly_sync(self, "monthplot", offsets.monthplot, function()
        maybe_sync_monthplot(self, false)
    end)
    schedule_hourly_sync(self, "tariff", offsets.tariff, function()
        maybe_sync_tariff(self, false)
    end)
    schedule_hourly_sync(self, "sysinfo", offsets.sysinfo, function()
        maybe_sync_sysinfo(self, false)
    end)
    schedule_hourly_sync(self, "configuration", offsets.configuration, function()
        maybe_sync_configuration(self, false)
    end)
end

local function childPropsFromDef(def)
    return {
        name = def.name,
        type = def.type,
        properties = def.properties,
        interfaces = def.interfaces,
        store = def.store,
        room = def.room,
    }
end

local function createMissingChildren(self, childrenDefs)
    local uidMap = self:getChildrenUidMap() or {}

    for uid, def in pairs(childrenDefs) do
        local existing = uidMap[uid]
        if not existing or not existing.id then
            print(string.format("Creating child %s (%s)", tostring(uid), tostring(def.name)))
            self:createChild(uid, childPropsFromDef(def), def.className, def.UI)
        end
    end
end

local function ensureChildDefinition(self, childrenDefs, uid)
    local def = childrenDefs[uid]
    if type(def) ~= "table" then return end

    local uidMap = self:getChildrenUidMap() or {}
    local existing = uidMap[uid]
    if not existing or not existing.id then return end

    local device = api.get("/devices/" .. existing.id)
    local actualType = device and device.type or nil
    local actualClass = existing.className or ""

    if actualType ~= def.type or actualClass ~= def.className then
        print(string.format(
            "Recreating child %s (%s/%s -> %s/%s)",
            uid,
            tostring(actualType),
            tostring(actualClass),
            tostring(def.type),
            tostring(def.className)
        ))

        self:createChild(uid, childPropsFromDef(def), def.className, def.UI)
        return
    end

    local actualName = device and device.name or ""
    if actualName ~= def.name then
        print(string.format(
            "Renaming child %s (%s -> %s)",
            uid,
            tostring(actualName),
            tostring(def.name)
        ))
        pcall(function()
            api.put("/devices/" .. existing.id, { name = def.name })
        end)
    end
end

local function syncChildDefinitions(self, childrenDefs)
    for uid,_ in pairs(childrenDefs) do
        ensureChildDefinition(self, childrenDefs, uid)
    end
end






















-------------------------------------------------------------------------------------------------------------------------------
-------------------------------------------------------------------------------------------------------------------------------
-------------------------------------------------------------------------------------------------------------------------------
-------------------------------------------------------------------------------------------------------------------------------
-------------------------------------------------------------------------------------------------------------------------------
-------------------------------------------------------------------------------------------------------------------------------
-------------------------------------------------------------------------------------------------------------------------------
-------------------------------------------------------------------------------------------------------------------------------
-------------------------------------------------------------------------------------------------------------------------------
-------------------------------------------------------------------------------------------------------------------------------
-------------------------------------------------------------------------------------------------------------------------------
-------------------------------------------------------------------------------------------------------------------------------
-------------------------------------------------------------------------------------------------------------------------------
-------------------------------------------------------------------------------------------------------------------------------
-------------------------------------------------------------------------------------------------------------------------------
-------------------------------------------------------------------------------------------------------------------------------
-------------------------------------------------------------------------------------------------------------------------------
-------------------------------------------------------------------------------------------------------------------------------
-------------------------------------------------------------------------------------------------------------------------------
-------------------------------------------------------------------------------------------------------------------------------
-------------------------------------------------------------------------------------------------------------------------------
-------------------------------------------------------------------------------------------------------------------------------
-------------------------------------------------------------------------------------------------------------------------------
-------------------------------------------------------------------------------------------------------------------------------
-------------------------------------------------------------------------------------------------------------------------------
-------------------------------------------------------------------------------------------------------------------------------
-------------------------------------------------------------------------------------------------------------------------------
-------------------------------------------------------------------------------------------------------------------------------
-------------------------------------------------------------------------------------------------------------------------------
-------------------------------------------------------------------------------------------------------------------------------
-------------------------------------------------------------------------------------------------------------------------------
-------------------------------------------------------------------------------------------------------------------------------
-------------------------------------------------------------------------------------------------------------------------------
-------------------------------------------------------------------------------------------------------------------------------
-------------------------------------------------------------------------------------------------------------------------------
-------------------------------------------------------------------------------------------------------------------------------
-------------------------------------------------------------------------------------------------------------------------------
-------------------------------------------------------------------------------------------------------------------------------
-------------------------------------------------------------------------------------------------------------------------------
-------------------------------------------------------------------------------------------------------------------------------
-------------------------------------------------------------------------------------------------------------------------------
-------------------------------------------------------------------------------------------------------------------------------
-- QuickApp methods in logical order
---@diagnostic disable-next-line
function QuickApp:onInit()
self:debug(self.name,self.id)
if not api.get("/devices/"..self.id).enabled then
    self:debug(self.name,self.id,"Device is disabled")
    return
end
self.store = self:setupStorage()
self.runtime = {
    last_data_fetch = "Never",
    last_data_fetch_status = "No data yet",
    consecutive_fetch_errors = 0,
    ams_auth_mode = "unknown",
    ams_online = true,
    total_power_factor = nil,
    ams_temperature = nil,
    ams_uptime_seconds = nil,
    ams_free_memory_bytes = nil,
    ams_clock = nil,
    ams_import_max_power = nil,
    ams_export_max_power = nil,
    ams_meter_type = nil,
    ams_distribution_system = nil,
    ams_main_fuse_size = nil,
    total_power_factor_raw_failures = 0,
    total_power_factor_last_update_ts = 0,
    phase_power_factor_raw_failures = { l1 = 0, l2 = 0, l3 = 0 },
    phase_power_factor_raw_values = { l1 = nil, l2 = nil, l3 = nil },
    phase_power_factor_last_update_ts = 0,
    phase_power_factor_sources = { l1 = "raw", l2 = "raw", l3 = "raw" },
    phase_power_factor_snapshots = { l1 = nil, l2 = nil, l3 = nil },
    kb_val_max = 0.0001,
    kbc_val_max = 0.0001,
    cpp_val_max = 0.0001,
    minmax_state = nil,
}
load_minmax_state(self)


---@diagnostic disable-next-line
local self_room_name = hub.getRoomName(hub.getRoomID(self.id)) or "no data"
self:debug("DeviceId:",self.id, "   " ,"Name:", self.name)
self:debug("Room:",hub.getRoomID(self.id), "   " ,"Room Name:", self_room_name)
self:updateProperty("log", get_main_log_text())
self:updateProperty("deviceRole", "Other")
self:updateProperty("categories",{"other"})
--self:updateProperty("useUiView",false)
--self:updateProperty("hasUIView",false)
local ui_view = api.get("/devices/"..self.id.."")
--print("hasUIView: ",json.encode(ui_view.hasUIView))
--print("useUiView: ",json.encode(ui_view.properties.useUiView))
if ui_view.properties.useUiView == true then
api.put("/devices/" .. self.id, {properties = {  useUiView = false } })
end

hub.setTimeout(tonumber(AMS_ICON_CONFIG.installDelayMs) or 1500, function()
    self:installAmsIcon(true, function(ok, value, state)
        if not ok then
            self:warning("AMS icon install failed: " .. tostring(value))
            return
        end
        self:debug("AMS icon ready:", tostring(value), tostring(state))
    end, AMS_ICON_CONFIG.uploadTimeoutMs, 1)
end)





-------------------------------------------------------------------------------------------------------------------------------
-------------------------------------------------------------------------------------------------------------------------------
local response_data = {}
local ams_host = tostring(self:getVariable("AMS_IP") or "192.168.30.82")
ams_host = ams_host:gsub("^%s+", ""):gsub("%s+$", "")
if ams_host == "" then ams_host = "192.168.30.82" end
local ams_base_url = ams_host
if not ams_base_url:match("^https?://") then
    ams_base_url = "http://"..ams_base_url
end
ams_base_url = ams_base_url:gsub("/+$", "")
local function ams_url(path)
    return ams_base_url .. path
end

-------------------------------------------------------------------------------------------------------------------------------
-------------------------------------------------------------------------------------------------------------------------------
------label colors — defined in config.colors, no QA variables needed

-------------------------------------------------------------------------------------------------------------------------------
-------------------------------------------------------------------------------------------------------------------------------
local refresh_mem = tonumber(config.refresh_mem_interval) or 60
--------------------------------------------------------------------------------------------------------------------------------
--------------------------------------------------------------------------------------------------------------------------------
-----just to fixs labels/buttons not showing
--------------------------------------------------------------------------------------------------------------------------------
--------------------------------------------------------------------------------------------------------------------------------
local hide_label = {
"s1",
"s2",
"s3",
"s4",
"s5",
"s6",
"s7",
"s8",
"s9",
"s10",
"s11",
"s12",
"s13"
} 
for _,val in pairs(hide_label) do self:updateView(val,"text","") end
for _,val in pairs(hide_label) do self:updateView(val,"visible",false) end

-------------------------------------------------------------------------------------------------------------------------------
-------------------------------------------------------------------------------------------------------------------------------
--------- first time QA runs
if self.store.first_time == nil then   ----       ~=
--if 0 == 0 then
-------



self:initChildren(Child_table)


-------
self.runtime.kbc_val_max = 0.0001
self.runtime.cpp_val_max = 0.0001
self.runtime.kb_val_max = 0.0001
-------
self.store.first_time = "First time Installation is Done"
print(self.store.first_time)
end---if self.store.first_time == nil then 

----------------------------------------------------------------
----------------------------------------------------------------
local setup = self:getVariable("Setup") or "0"
if setup ~= "0" then
self:setVariable("Setup", "0")
-------



self:initChildren(Child_table)

-------
self.runtime.kbc_val_max = 0.0001
self.runtime.cpp_val_max = 0.0001
self.runtime.kb_val_max = 0.0001
-------
self.store.first_time = "First time Installation is Done"
print(self.store.first_time)
end-- if setup ~= "0" then
-------------------------------------------------------------------------------------------------------------------------------
-------------------------------------------------------------------------------------------------------------------------------

-------------------------------------------------------------------------------------------------------------------------------
-------------------------------------------------------------------------------------------------------------------------------
---load children that exsist
---
createMissingChildren(self, Child_table)
self:loadExistingChildren(Child_table)
syncChildDefinitions(self, Child_table)
import_monthplot_seed(self)
local tariff_state = load_tariff_state(self)
local accounting_state = load_energyaccounting_state(self)
apply_tariff_state(self, tariff_state)
update_tariff_children(self)
update_hourly_accounting_children(self, accounting_state)
update_daily_accounting_children(self, accounting_state)
update_monthly_accounting_children(self, accounting_state)
update_last_hour_import_child(self)
update_yesterday_import_child(self)
Child_table["s49"].store.value = true
update_child_from_table(self, "s49")

--self:initChildren(Child_table)


------------------------------
local logError  -- forward declaration; assigned after kb/kbc/cpp locals below
------------------------------
function UpdateChildren()
dbg("-------------------------------------")
dbg("updateChildren")
dbg("-------------------------------------")
if type(response_data) == "string" then
    local ok, decoded = pcall(json.decode, response_data)
    if not ok or type(decoded) ~= "table" then
        print("updateChildren decode error: ", decoded)
        self.runtime.last_data_fetch_status = "Decode error"
        self.runtime.consecutive_fetch_errors = (tonumber(self.runtime.consecutive_fetch_errors) or 0) + 1
        if logError then logError("Decode error: " .. tostring(decoded)) end
        return false
    end
    response_data = decoded
elseif type(response_data) ~= "table" then
    print("updateChildren invalid payload type: ", type(response_data))
    self.runtime.last_data_fetch_status = "Invalid payload"
    self.runtime.consecutive_fetch_errors = (tonumber(self.runtime.consecutive_fetch_errors) or 0) + 1
    if logError then logError("Invalid payload type: " .. type(response_data)) end
    return false
end
dbg("response_data: ",response_data)

local l1 = response_data.l1 or {}
local l2 = response_data.l2 or {}
local l3 = response_data.l3 or {}

if response_data.i ~= nil then Child_table["s1"].store.value = response_data.i end
if response_data.e ~= nil then Child_table["s2"].store.value = response_data.e end
if response_data.w ~= nil then Child_table["s3"].store.value = response_data.w end
if response_data.ri ~= nil then Child_table["s4"].store.value = response_data.ri end
if response_data.re ~= nil then Child_table["s5"].store.value = response_data.re end
register_total_power_factor_reading(self, response_data.f)

if response_data.ic ~= nil then Child_table["s6"].store.value = response_data.ic end
if response_data.ec ~= nil then Child_table["s7"].store.value = response_data.ec end
if response_data.ric ~= nil then Child_table["s8"].store.value = response_data.ric end
if response_data.rec ~= nil then Child_table["s9"].store.value = response_data.rec end
if response_data.p ~= nil then Child_table["s33"].store.value = response_data.p end
if response_data.px ~= nil then Child_table["s34"].store.value = response_data.px end
if response_data.t ~= nil then self.runtime.ams_temperature = response_data.t end
if response_data.u ~= nil then self.runtime.ams_uptime_seconds = response_data.u end
if response_data.m ~= nil then self.runtime.ams_free_memory_bytes = response_data.m end
if response_data.im ~= nil then self.runtime.ams_import_max_power = response_data.im end
if response_data.om ~= nil then self.runtime.ams_export_max_power = response_data.om end
if response_data.mf ~= nil then self.runtime.ams_main_fuse_size = response_data.mf end
if response_data.mt ~= nil then self.runtime.ams_meter_type = response_data.mt end
if response_data.ds ~= nil then self.runtime.ams_distribution_system = response_data.ds end
if response_data.c ~= nil then self.runtime.ams_clock = response_data.c end
if response_data.ea ~= nil then
    local ok, err = sync_energyaccounting_from_payload(self, response_data.ea)
    if not ok then
        dbg("energyaccounting sync failed", err)
        if logError then logError("energyaccounting sync: " .. tostring(err)) end
    else
        local accounting_state = load_energyaccounting_state(self)
        update_hourly_accounting_children(self, accounting_state)
        update_daily_accounting_children(self, accounting_state)
        update_monthly_accounting_children(self, accounting_state)
    end
end

if l1.u ~= nil then Child_table["s10"].store.value = l1.u end
if l1.i ~= nil then Child_table["s11"].store.value = l1.i end
if l1.p ~= nil then Child_table["s12"].store.value = round0(l1.p) end
Child_table["s42"].store.value = calculate_phase_apparent_power(l1, Child_table["s42"].store.value)
if l1.q ~= nil then Child_table["s13"].store.value = l1.q end
register_phase_power_factor_reading(self, "l1", l1.f)

if l2.u ~= nil then Child_table["s15"].store.value = l2.u end
if l2.i ~= nil then Child_table["s16"].store.value = l2.i end
if l2.p ~= nil then Child_table["s17"].store.value = round0(l2.p) end
Child_table["s43"].store.value = calculate_phase_apparent_power(l2, Child_table["s43"].store.value)
if l2.q ~= nil then Child_table["s18"].store.value = l2.q end
register_phase_power_factor_reading(self, "l2", l2.f)

if l3.u ~= nil then Child_table["s20"].store.value = l3.u end
if l3.i ~= nil then Child_table["s21"].store.value = l3.i end
if l3.p ~= nil then Child_table["s22"].store.value = round0(l3.p) end
Child_table["s44"].store.value = calculate_phase_apparent_power(l3, Child_table["s44"].store.value)
if l3.q ~= nil then Child_table["s23"].store.value = l3.q end
register_phase_power_factor_reading(self, "l3", l3.f)

update_minmax_state(self)

refresh_total_power_factor_child(self, (tonumber(self.runtime.total_power_factor_last_update_ts) or 0) == 0)
refresh_phase_power_factor_children(self, (tonumber(self.runtime.phase_power_factor_last_update_ts) or 0) == 0)

for uid,child in pairs(self.children) do
--print("updateChildren uid: ",uid)
--print("updateChildren child: ",child)
    if uid ~= "s14" and uid ~= "s19" and uid ~= "s24" and uid ~= "s41" then
        child:update(Child_table, uid)
    end
end--uid,child in pairs(self.children) do
return true
end

-------------------------------------------------------------------------------------------------------------------------------
-------------------------------------------------------------------------------------------------------------------------------



--print("Self.properties.quickAppVariables: ", self.properties.quickAppVariables[1].value)
    
--print("Self.properties.quickAppVariables: ", json.encode(self.properties.quickAppVariables))
    
    

-------------------------------------------------------------------------------------------------------------------------------
-------------------------------------------------------------------------------------------------------------------------------
-- self:initChildren(Child_table)
-------------------------------------------------------------------------------------------------------------------------------
-------------------------------------------------------------------------------------------------------------------------------

-- Shared GET helper — creates a new HTTPClient per call (safe for concurrent requests)
local function http_get(path, on_success, on_error)
    local url = ams_url(path)
    local auth_header = get_ams_auth_header(self)

    local function request_with_auth(use_auth, attempted_auth_retry)
        local headers = { ["Accept"] = "application/json" }
        if use_auth == true and auth_header ~= nil and auth_header ~= "" then
            headers["Authorization"] = auth_header
        end

        net.HTTPClient():request(url, {
            options = {
                method  = "GET",
                timeout = config.http_timeout,
                headers = headers,
            },
            success = function(response)
                local status = tonumber(response.status or 0)
                if status < 200 or status >= 300 then
                    local auth_required = status == 401 or status == 403
                    if auth_required and use_auth ~= true then
                        self.runtime.ams_auth_mode = "required"
                        if auth_header ~= nil and auth_header ~= "" and attempted_auth_retry ~= true then
                            request_with_auth(true, true)
                            return
                        end
                        if on_error then
                            on_error("Auth required, no credentials (HTTP " .. tostring(status) .. ")")
                        end
                        print("HTTP auth required", url, "status", status, response.data or "")
                        return
                    elseif auth_required and use_auth == true then
                        self.runtime.ams_auth_mode = "failed"
                        if on_error then
                            on_error("Auth failed, check Username/Password (HTTP " .. tostring(status) .. ")")
                        end
                        print("HTTP auth failed", url, "status", status, response.data or "")
                        return
                    end

                    print("HTTP error", url, "status", status, response.data or "")
                    if on_error then on_error("HTTP "..tostring(status)) end
                    return
                end

                if use_auth == true and auth_header ~= nil and auth_header ~= "" then
                    self.runtime.ams_auth_mode = "required"
                else
                    self.runtime.ams_auth_mode = "disabled"
                end

                dbg("HTTP ok", path, response.data)
                if on_success then on_success(response.data) end
            end,
            error = function(err)
                print("HTTP error", url, tostring(err))
                if on_error then on_error(tostring(err)) end
            end
        })
    end

    local auth_mode = tostring(self.runtime.ams_auth_mode or "unknown")
    local use_auth_first = auth_mode == "required" and auth_header ~= nil and auth_header ~= ""
    request_with_auth(use_auth_first, false)
    dbg("HTTP GET", path)
end

local function print_json_response_to_console(label, body)
    print("===== " .. tostring(label or "JSON") .. " =====")
    print(tostring(body or ""))
end

local function Http_get_json_debug(path)
    http_get(path,
        function(body)
            print_json_response_to_console(path, body)
        end,
        function(err)
            print(path .. " fetch failed:", err)
            if logError then logError("HTTP " .. tostring(path) .. ": " .. tostring(err)) end
        end
    )
end

local function update_online_child(self, is_online)
    local online = is_online == true
    self.runtime.ams_online = online
    Child_table["s49"].store.value = online
    update_child_from_table(self, "s49")
end

local refresh_live_ui_cards, maybe_refresh_live_ui_cards

function Http_get_data()
    if self.data_request_inflight == true then
        dbg("Skipping /data.json poll because a previous request is still in flight")
        return
    end

    self.data_request_inflight = true
    http_get("/data.json",
        function(body)
            self.data_request_inflight = false
            self.runtime.last_data_fetch = os.date("%Y-%m-%d %H:%M:%S")
            response_data              = body
            local updated = UpdateChildren()
            if updated then
                self.runtime.last_data_fetch_status   = "OK"
                self.runtime.consecutive_fetch_errors = 0
                update_online_child(self, true)
            end
            maybe_refresh_live_ui_cards(self, false)
        end,
        function(err)
            self.data_request_inflight = false
            self.runtime.last_data_fetch              = os.date("%Y-%m-%d %H:%M:%S")
            self.runtime.last_data_fetch_status       = err
            self.runtime.consecutive_fetch_errors     = (tonumber(self.runtime.consecutive_fetch_errors) or 0) + 1
            if (tonumber(self.runtime.consecutive_fetch_errors) or 0) >= (tonumber(config.offline_after_http_failures) or 10) then
                update_online_child(self, false)
            end
            if logError then logError("HTTP data.json: " .. tostring(err)) end
            maybe_refresh_live_ui_cards(self, false)
        end
    )
end

Http_get_data()

if config.update_interval and config.update_interval > 0 then
local data_update_interval_ms = get_data_update_interval_ms()
if data_update_interval_ms > 0 then
setInterval(function()
    Http_get_data()
end, data_update_interval_ms)
end
end

-------------------------------------------------------------------------------------------------------------------------------
-------------------------------------------------------------------------------------------------------------------------------

function Http_get_sysinfo()
    if self.sysinfo_request_inflight == true then return end
    self.sysinfo_request_inflight = true

    http_get("/sysinfo.json",
        function(body)
            self.sysinfo_request_inflight = false
            local ok, err = sync_sysinfo_from_payload(self, body)
            if ok then
                UpdateInfoAms()
            else
                print("sysinfo sync failed:", tostring(err))
                if logError then logError("sysinfo sync: " .. tostring(err)) end
            end
        end,
        function(err)
            self.sysinfo_request_inflight = false
            print("sysinfo fetch failed:", err)
            if logError then logError("HTTP sysinfo.json: " .. tostring(err)) end
        end
    )
end

-------------------------------------------------------------------------------------------------------------------------------
-------------------------------------------------------------------------------------------------------------------------------

function Http_get_energyprice(target_hour_ts, dump_to_console)
    local sync_hour_ts = math.floor(tonumber(target_hour_ts) or get_hour_start_ts())
    http_get("/energyprice.json",
        function(body)
            if dump_to_console == true then
                print_json_response_to_console("/energyprice.json", body)
            end
            local ok, err, price_info = sync_energyprice_from_payload(self, body, sync_hour_ts)
            if ok then
                if logError and type(price_info) == "table" then
                    local reused = tonumber(price_info.reused_previous_values) or 0
                    local missing = tonumber(price_info.missing_zero_values) or 0
                    if reused > 0 or missing > 0 then
                        logError(string.format(
                            "energyprice missing: reused %d old value(s), missing %d slot(s)",
                            reused,
                            missing
                        ))
                    end
                end
                update_hourly_accounting_children(self)
                update_daily_accounting_children(self)
                update_monthly_accounting_children(self)
                UpdateInfoPrice()
            else
                print("energyprice sync failed:", tostring(err))
                if logError then logError("energyprice sync: " .. tostring(err)) end
            end
        end,
        function(err)
            print("energyprice fetch failed:", err)
            if logError then logError("HTTP energyprice.json: " .. tostring(err)) end
        end
    )
end

-------------------------------------------------------------------------------------------------------------------------------
-------------------------------------------------------------------------------------------------------------------------------

function Http_get_dayplot(target_hour_ts)
    local sync_hour_ts = math.floor(tonumber(target_hour_ts) or (get_hour_start_ts() - 3600))
    http_get("/dayplot.json",
        function(body)
            local ok, err = sync_hour_history_from_dayplot(self, body, sync_hour_ts)
            if ok then
                update_last_hour_import_child(self)
                UpdateInfoHours()
            else
                print("dayplot sync failed:", tostring(err))
                if logError then logError("dayplot sync: " .. tostring(err)) end
            end
        end,
        function(err)
            print("dayplot fetch failed:", err)
            if logError then logError("HTTP dayplot.json: " .. tostring(err)) end
        end
    )
end

function Http_get_monthplot(target_month_ts)
    local sync_month_ts = math.floor(tonumber(target_month_ts) or os.time())
    http_get("/monthplot.json",
        function(body)
            local ok, err = sync_month_history_from_monthplot(self, body, sync_month_ts)
            if ok then
                update_yesterday_import_child(self)
                UpdateInfoDays()
                UpdateInfoMonths()
            else
                print("monthplot sync failed:", tostring(err))
                if logError then logError("monthplot sync: " .. tostring(err)) end
            end
        end,
        function(err)
            print("monthplot fetch failed:", err)
            if logError then logError("HTTP monthplot.json: " .. tostring(err)) end
        end
    )
end

function Http_get_tariff(target_hour_ts)
    local sync_hour_ts = math.floor(tonumber(target_hour_ts) or get_hour_start_ts())
    http_get("/tariff.json",
        function(body)
            local ok, err = sync_tariff_from_payload(self, body, sync_hour_ts)
            if ok then
                update_tariff_children(self)
                Info()
                UpdateInfoTariff()
            else
                print("tariff sync failed:", tostring(err))
                if logError then logError("tariff sync: " .. tostring(err)) end
            end
        end,
        function(err)
            print("tariff fetch failed:", err)
            if logError then logError("HTTP tariff.json: " .. tostring(err)) end
        end
    )
end

function Http_get_configuration(dump_to_console)
    if self.configuration_request_inflight == true then
        if dump_to_console == true then
            self:warning("configuration.json request already running")
        end
        return
    end
    self.configuration_request_inflight = true

    http_get("/configuration.json",
        function(body)
            self.configuration_request_inflight = false
            if dump_to_console == true then
                print_json_response_to_console("/configuration.json", body)
                local decoded = decode_json_table(body)
                if type(decoded) == "table" then
                    print("===== /configuration.json p =====")
                    print(json.encode(type(decoded.p) == "table" and decoded.p or {}))
                end
            end
            local ok, err = sync_configuration_from_payload(self, body)
            if ok then
                update_hourly_accounting_children(self)
                update_daily_accounting_children(self)
                update_monthly_accounting_children(self)
                UpdateInfoAms()
            else
                print("configuration sync failed:", tostring(err))
                if logError then logError("configuration sync: " .. tostring(err)) end
            end
        end,
        function(err)
            self.configuration_request_inflight = false
            print("configuration fetch failed:", err)
            if logError then logError("HTTP configuration.json: " .. tostring(err)) end
        end
    )
end

function Http_get_priceconfig_debug()
    http_get("/priceconfig.json",
        function(body)
            print_json_response_to_console("/priceconfig.json", body)
        end,
        function(err)
            print("priceconfig fetch failed:", err)
            if logError then logError("HTTP priceconfig.json: " .. tostring(err)) end
        end
    )
end



-------------------------------------------------------------------------------------------------------------------------------
-------------------------------------------------------------------------------------------------------------------------------
local function build_hour_history_rows()
    local rows = {}
    local hour_history = load_hour_history(self)
    if #hour_history == 0 then
        rows[1] = {icon="📅", label="Waiting for first completed hour", value="-"}
    else
        for _, entry in ipairs(hour_history) do
            local ts = tonumber(entry.ts)
            local value = tonumber(entry.value) or 0
            local label = ts and format_day_hour_label(ts) or "-"
            if entry.corrected == true then
                label = label .. "(c)"
            end
            rows[#rows+1] = {
                icon = "📅",
                label = label,
                value = string.format("⚡ %.2f kWh", value),
            }
        end
    end
    return rows
end

local function build_energyprice_rows()
    local rows = {}
    local schedule = load_energyprice_schedule(self)
    local entries = schedule.entries or {}
    local source = schedule.source
    local currency = schedule.currency
    local import_value = tonumber(Child_table["s33"] and Child_table["s33"].store and Child_table["s33"].store.value)
    local export_value = tonumber(Child_table["s34"] and Child_table["s34"].store and Child_table["s34"].store.value)
    local price_unit = (Child_table["s33"] and Child_table["s33"].store and Child_table["s33"].store.unit) or "kr/kWh"

    local function fmt_current_price(value)
        if value == nil then return "-" end
        return string.format("💰 %.4f %s", value, price_unit)
    end

    rows[#rows+1] = {
        icon = "📥",
        label = "Import",
        value = fmt_current_price(import_value),
    }
    rows[#rows+1] = {
        icon = "📤",
        label = "Export",
        value = fmt_current_price(export_value),
    }

    rows[#rows+1] = {
        icon = "🏷️",
        label = "Source",
        value = (source ~= nil and source ~= "") and source or "-",
    }
    rows[#rows+1] = {
        icon = "💲",
        label = "Currency",
        value = (currency ~= nil and currency ~= "") and ("💰 " .. currency) or "-",
    }

    if #entries == 0 then
        rows[#rows+1] = {icon = "⏳", label = "Waiting for energy prices", value = "-"}
        return rows
    end

    for _, entry in ipairs(entries) do
        local ts = tonumber(entry.ts)
        local label = ts and format_day_hour_label(ts) or string.format("+%02d h", tonumber(entry.offset) or 0)
        local value = "⏳ Unknown"
        local icon = "📅"
        if entry.corrected == true then
            label = label .. "(c)"
        end

        if entry.known == true and entry.value ~= nil then
            value = string.format("💰 %.4f", tonumber(entry.value) or 0)
            if currency ~= nil and currency ~= "" then
                value = value .. " " .. currency
            end
        else
            icon = "📅"
        end

        rows[#rows+1] = {
            icon = icon,
            label = label,
            value = value,
        }
    end

    return rows
end

local function build_day_history_rows()
    local rows = {}
    local month_history = load_month_history(self)
    if #month_history == 0 then
        rows[1] = {icon="📅", label="Waiting for month plot", value="-"}
    else
        local total = 0
        for _, entry in ipairs(month_history) do
            local ts = tonumber(entry.ts)
            local value = tonumber(entry.value) or 0
            total = total + value
            rows[#rows+1] = {
                icon = "📅",
                label = ts and os.date("%d/%m", ts) or "-",
                value = string.format("⚡ %.2f kWh", value),
            }
        end

        rows[#rows+1] = {
            icon = "📊",
            label = "Avg",
            value = string.format("⚡ %.2f kWh", total / #month_history),
        }
    end
    return rows
end

local function build_month_totals_rows()
    local rows = {}
    local month_totals = get_month_totals_history_for_display(self)
    if #month_totals == 0 then
        rows[1] = {icon="📅", label="Waiting for month totals", value="-"}
    else
        local current_year = nil
        local year_total = 0

        for _, entry in ipairs(month_totals) do
            local ts = tonumber(entry.ts)
            local value = tonumber(entry.value) or 0
            local days_in_month = ts and get_days_in_month(ts) or 30
            local avg_each_day = days_in_month > 0 and (value / days_in_month) or 0

            local year_label = ts and os.date("%Y", ts) or "-"
            if current_year ~= year_label then
                if current_year ~= nil then
                    rows[#rows+1] = {
                        icon = "∑",
                        label = "Year " .. tostring(current_year) .. " Tot",
                        value = string.format("⚡ %.2f kWh", year_total),
                        lc = config.colors.color4,
                        vc = config.colors.color4,
                    }
                end
                if current_year ~= nil then
                    rows[#rows+1] = { divider = true }
                end

                current_year = year_label
                year_total = 0
                rows[#rows+1] = {
                    icon = "📘",
                    label = "Year " .. tostring(year_label),
                    value = "",
                    lc = config.colors.color4,
                    vc = config.colors.color4,
                }
            end

            year_total = year_total + value
            rows[#rows+1] = {
                icon = "📅",
                label = ts and os.date("%m/%Y", ts) or "-",
                value = string.format("⚡ %.2f kWh", value),
            }
            rows[#rows+1] = {
                icon = "📊",
                label = "Avg Each Day",
                value = string.format("⚡ %.2f kWh", avg_each_day),
                vc = config.colors.color4,
            }
        end

        if current_year ~= nil then
            rows[#rows+1] = {
                icon = "∑",
                label = "Year " .. tostring(current_year) .. " Tot",
                value = string.format("⚡ %.2f kWh", year_total),
                lc = config.colors.color4,
                vc = config.colors.color4,
            }
        end
    end
    return rows
end

local function build_tariff_rows()
    local rows = {}
    local tariff = load_tariff_state(self)
    local threshold = tonumber(tariff.current_threshold)
    local peaks = tariff.peaks or {}
    local month_avg = tonumber(tariff.month_avg)

    rows[#rows+1] = {
        icon = "🎯",
        label = "Month Threshold",
        value = threshold ~= nil and (string.format("%g", threshold) .. " kWh") or "-",
    }

    if #peaks == 0 and month_avg == nil then
        rows[#rows+1] = {icon="⏳", label="Waiting for tariff data", value="-"}
    else
        local medals = {"🥇", "🥈", "🥉"}
        for i = 1, 3 do
            local peak = peaks[i]
            rows[#rows+1] = {
                icon = medals[i],
                label = peak and string.format("Peak %d Day %02d", i, tonumber(peak.day) or 0) or ("Peak " .. tostring(i)),
                value = peak and string.format("⚡ %.2f kWh", tonumber(peak.value) or 0) or "-",
            }
        end

        rows[#rows+1] = {
            icon = "📊",
            label = "Avg (P1+P2+P3)",
            value = month_avg ~= nil and string.format("⚡ %.2f kWh", month_avg) or "-",
        }
    end

    rows[#rows+1] = {
        icon = "🕐",
        label = "Last sync",
        value = (tariff.last_sync ~= nil and tariff.last_sync ~= "") and tariff.last_sync or "Never",
    }

    return rows
end

local function build_energyaccounting_rows()
    local rows = {}
    local state = load_energyaccounting_state(self)
    local schedule = load_energyprice_schedule(self)
    local currency = tostring(schedule.currency or "")
    if currency == "" then currency = "kr" end

    local function fmt_energy(value)
        if value == nil then return "-" end
        return string.format("⚡ %.2f kWh", tonumber(value) or 0)
    end

    local function fmt_money(value)
        if value == nil then return "-" end
        return string.format("💰 %.2f %s", tonumber(value) or 0, currency)
    end

    rows[#rows+1] = {
        icon = "🎯",
        label = "Active Threshold",
        value = state.threshold ~= nil and (string.format("%g", state.threshold) .. " kWh") or "-",
    }
    rows[#rows+1] = {
        icon = "📈",
        label = "Max Average",
        value = fmt_energy(state.x),
    }

    if #state.peaks == 0 then
        rows[#rows+1] = {icon="⏳", label="Tariff Peaks", value="-"}
    else
        local medals = {"🥇", "🥈", "🥉"}
        for i, peak in ipairs(state.peaks) do
            rows[#rows+1] = {
                icon = medals[i] or "🏅",
                label = "Peak " .. tostring(i),
                value = fmt_energy(peak),
            }
        end
    end

    rows[#rows+1] = {icon="📥", label="Hour Import",       value=fmt_energy(state.h.u)}
    rows[#rows+1] = {icon="💸", label="Hour Cost",         value=fmt_money(state.h.c)}
    rows[#rows+1] = {icon="📤", label="Hour Export",       value=fmt_energy(state.h.p)}
    rows[#rows+1] = {icon="💰", label="Hour Income",       value=fmt_money(state.h.i)}
    rows[#rows+1] = {icon="📥", label="Today Import",      value=fmt_energy(state.d.u)}
    rows[#rows+1] = {icon="💸", label="Today Cost",        value=fmt_money(state.d.c)}
    rows[#rows+1] = {icon="📤", label="Today Export",      value=fmt_energy(state.d.p)}
    rows[#rows+1] = {icon="💰", label="Today Income",      value=fmt_money(state.d.i)}
    rows[#rows+1] = {icon="📥", label="Month Import",      value=fmt_energy(state.m.u)}
    rows[#rows+1] = {icon="💸", label="Month Cost",        value=fmt_money(state.m.c)}
    rows[#rows+1] = {icon="📤", label="Month Export",      value=fmt_energy(state.m.p)}
    rows[#rows+1] = {icon="💰", label="Month Income",      value=fmt_money(state.m.i)}
    rows[#rows+1] = {
        icon = "🕐",
        label = "Last sync",
        value = (state.last_sync ~= nil and state.last_sync ~= "") and state.last_sync or "Never",
    }

    return rows
end

function UpdateInfoHours()
    local content = build_card("🕘", "Last " .. tostring(config.hour_history_limit) .. " Hours", build_hour_history_rows())
    self:updateView("info_hours", "text", with_top_divider(content))
end

function UpdateInfoPrice()
    local schedule = load_energyprice_schedule(self)
    local title = "Energy Price"
    if schedule.currency ~= nil and schedule.currency ~= "" then
        title = title .. " " .. tostring(schedule.currency)
    end
    local content = build_card("💹", title, build_energyprice_rows())
    self:updateView("info_price", "text", with_top_divider(content))
end

function UpdateInfoUrl()
    local url = ams_base_url .. "/"
    local iconSource = getAmsIconDataUrl()
    local buttonHtml

    if type(iconSource) == "string" and iconSource ~= "" then
        buttonHtml = string.format(
            "<a href='%s'><img src='%s' alt='Open AMS Web' width='%d' height='%d'/></a>",
            url,
            iconSource,
            AMS_ICON_CONFIG.buttonSizePx,
            AMS_ICON_CONFIG.buttonSizePx
        )
    else
        buttonHtml = "<a href='" .. url .. "'>Open AMS Web</a>"
    end

    local parts = {}
    parts[#parts+1] = build_divider()
    parts[#parts+1] = "<table width=" .. config.ui.widthPx .. " border=0 style='table-layout:fixed;'>"
    parts[#parts+1] = "<tr><td colspan=2 align=left>" ..
        "<font size='" .. config.ui.titleFontSize .. "'>" ..
        paint("<b>🌐 AMS Web</b>", config.colors.color1) ..
        "</font></td></tr>"
    parts[#parts+1] = "<tr><td colspan=2 align=center>" .. buttonHtml .. "</td></tr>"
    parts[#parts+1] = "<tr><td colspan=2 align=center><font size='" .. config.ui.bodyFontSize .. "'>" ..
        paint(url, config.colors.color2) ..
        "</font></td></tr>"
    parts[#parts+1] = "<tr><td colspan=2 align=center><font size='" .. config.ui.bodyFontSize .. "'>" ..
        paint("Warning: only works on local network", AMS_ICON_CONFIG.warningColor) ..
        "</font></td></tr>"
    parts[#parts+1] = "</table>"

    self:updateView("info_url", "text", table.concat(parts))
end

function UpdateInfoDays()
    local title = "Last " .. tostring(tonumber(config.month_history_limit) or 31) .. " Days"
    local content = build_card("📅", title, build_day_history_rows())
    self:updateView("info_days", "text", with_top_divider(content))
end

function UpdateInfoMonths()
    local title = "Last " .. tostring(tonumber(config.month_totals_history_limit) or 60) .. " Months"
    local content = build_card("🗓️", title, build_month_totals_rows())
    self:updateView("info_months", "text", with_top_divider(content))
end

function UpdateInfoTariff()
    apply_tariff_state(self, load_tariff_state(self))
    local content = build_card("📘", "Tariff", build_tariff_rows())
    self:updateView("info_tariff", "text", with_top_divider(content))
end

function UpdateInfoEnergyAccounting()
    local content = build_card("📒", "Energy Accounting", build_energyaccounting_rows())
    self:updateView("info_energyaccounting", "text", with_top_divider(content))
end

refresh_live_ui_cards = function(self)
    Info()
    UpdateInfoAms()
    UpdateInfoEnergyAccounting()
    UpdateInfoMonths()
    self.runtime.live_ui_last_refresh_ts = os.time()
end

maybe_refresh_live_ui_cards = function(self, force)
    local interval_ms = get_live_ui_refresh_interval_ms()
    if interval_ms <= 0 then
        refresh_live_ui_cards(self)
        return
    end

    local interval_sec = math.max(1, math.ceil(interval_ms / 1000))
    local now = os.time()
    local last_refresh_ts = tonumber(self.runtime.live_ui_last_refresh_ts) or 0

    if force == true or last_refresh_ts == 0 or (now - last_refresh_ts) >= interval_sec then
        refresh_live_ui_cards(self)
    end
end

function UpdateInfoAms()
    local function fmt_num(value, suffix, decimals)
        if value == nil or value == "" then return "-" end
        local n = tonumber(value)
        if n == nil then
            return suffix and (tostring(value) .. " " .. suffix) or tostring(value)
        end
        if decimals ~= nil then
            return string.format("%." .. tostring(decimals) .. "f", n) .. (suffix and (" " .. suffix) or "")
        end
        return tostring(n) .. (suffix and (" " .. suffix) or "")
    end

    local function fmt_text(value)
        if value == nil or value == "" then return "-" end
        return tostring(value)
    end

    local function fmt_uptime_hours(value)
        local seconds = tonumber(value)
        if seconds == nil then return fmt_text(value) end
        return string.format("%.1f h", seconds / 3600)
    end

    local function fmt_clock(value)
        local n = tonumber(value)
        if n == nil or n <= 0 then return "-" end
        if n ~= nil and n > 946684800 and n < 4102444800 then
            return os.date("%d/%m/%Y %H:%M:%S", n)
        end
        return fmt_text(value)
    end

    local function fmt_multiplier(value)
        local n = tonumber(value)
        if n == nil then return "-" end
        local text = string.format("%.3f", n)
        text = text:gsub("(%..-)0+$", "%1"):gsub("%.$", "")
        return text
    end

    local function fmt_price_region(value)
        local code = tostring(value or "")
        if code == "" then return "-" end

        local no_area = code:match("^10YNO%-(%d)")
        if no_area ~= nil then
            return "NO" .. tostring(no_area)
        end

        return code
    end

    local function fmt_interval(seconds)
        local n = tonumber(seconds)
        if n == nil or n <= 0 then return "-" end
        if n % 3600 == 0 then
            local hours = n / 3600
            local minutes = n / 60
            if hours == 1 then
                return "Every hour (60 min)"
            end
            return string.format("Every %d hours (%d min)", hours, minutes)
        end
        if n % 60 == 0 then
            return string.format("%d min", n / 60)
        end
        if n < 60 and n ~= math.floor(n) then
            return string.format("%.1f sec", n)
        end
        return string.format("%d sec", math.floor(n + 0.5))
    end

    local function fmt_hourly_slot(offset_seconds)
        local offset = math.max(0, math.min(3599, tonumber(offset_seconds) or 0))
        local hours = math.floor(offset / 3600)
        local minutes = math.floor((offset % 3600) / 60)
        local seconds = offset % 60
        return string.format("Hourly @ %02d:%02d:%02d", hours, minutes, seconds)
    end

    local function fmt_scheduled_refresh(interval_seconds, offset_seconds)
        local n = tonumber(interval_seconds)
        if n == nil or n <= 0 then return "-" end
        if n == 3600 then
            return fmt_hourly_slot(offset_seconds)
        end

        local offset = math.max(0, math.min(3599, tonumber(offset_seconds) or 0))
        local hours = math.floor(offset / 3600)
        local minutes = math.floor((offset % 3600) / 60)
        local seconds = offset % 60

        if n % 3600 == 0 then
            return string.format("Every %d hours @ %02d:%02d:%02d", n / 3600, hours, minutes, seconds)
        end

        return fmt_interval(n)
    end

    local function fmt_meter_type(value)
        local n = tonumber(value)
        if n == nil then return fmt_text(value) end
        if n == 1 then return "Aidon (1)" end
        if n == 2 then return "Kaifa (2)" end
        if n == 3 then return "Kamstrup (3)" end
        if n == 4 then return "Iskra (4)" end
        if n == 5 then return "Landis&Gyr (5)" end
        if n == 6 then return "Sagemcom (6)" end
        return tostring(n)
    end

    local function fmt_distribution_system(value)
        local n = tonumber(value)
        if n == nil then return fmt_text(value) end
        if n == 1 then return "IT 230V (1)" end
        if n == 2 then return "TN 400V (2)" end
        return tostring(n)
    end

    local function firmware_status()
        local current = tostring(self.store.ams_sysinfo_version or "")
        local from = tostring(self.store.ams_sysinfo_upgrade_from or "")
        local to = tostring(self.store.ams_sysinfo_upgrade_to or "")
        local booting = self.store.ams_sysinfo_booting == true
        local upgrading = self.store.ams_sysinfo_upgrading == true

        if upgrading then
            return to ~= "" and ("Installing " .. to) or "Installing"
        end
        if booting then
            return "Booting"
        end
        if to ~= "" and to ~= current then
            if from ~= "" and from ~= to then
                return from .. " -> " .. to
            end
            return "Available " .. to
        end
        if current ~= "" then
            return "Up to date"
        end
        return "-"
    end

    local function fmt_security_mode(value)
        local n = tonumber(value)
        if n == nil then return "-" end
        if n == 0 then return "No security (0)" end
        if n == 1 then return "Auth config (1)" end
        if n == 2 then return "Auth everything (2)" end
        return tostring(n)
    end

    local function fmt_price_interval(value)
        local n = tonumber(value)
        if n == nil or n <= 0 then return "-" end
        if math.floor(n) == n then
            return tostring(math.floor(n)) .. " min"
        end
        return tostring(n) .. " min"
    end

    local chip = fmt_text(self.store.ams_sysinfo_chip)
    local cpu = tonumber(self.store.ams_sysinfo_cpu)
    local chip_value = chip
    if chip ~= "-" and cpu ~= nil then
        chip_value = chip .. " / " .. tostring(cpu) .. " MHz"
    elseif chip == "-" and cpu ~= nil then
        chip_value = tostring(cpu) .. " MHz"
    end

    local errors = tonumber(self.runtime.consecutive_fetch_errors) or 0
    local err_color = errors > 0 and config.colors.color4 or nil
    local offsets = config.hourly_sync_offsets or {}
    local sysinfo_interval = tonumber(config.sysinfo_refresh_interval) or (60 * 60)
    local configuration_interval = tonumber(config.configuration_refresh_interval) or (60 * 60)
    local data_interval = get_data_update_interval_ms() / 1000

    local rows = {
        {icon="⏱️", label="Data.json",           value=fmt_interval(data_interval)},
        {icon="⏱️", label="Energyprice.json",    value=fmt_hourly_slot(offsets.energyprice)},
        {icon="⏱️", label="Dayplot.json",        value=fmt_hourly_slot(offsets.dayplot)},
        {icon="⏱️", label="Monthplot.json",      value=fmt_hourly_slot(offsets.monthplot)},
        {icon="⏱️", label="Tariff.json",         value=fmt_hourly_slot(offsets.tariff)},
        {icon="⏱️", label="Sysinfo.json",        value=fmt_scheduled_refresh(sysinfo_interval, offsets.sysinfo)},
        {icon="⏱️", label="Configuration.json",  value=fmt_scheduled_refresh(configuration_interval, offsets.configuration)},
        {icon="🕐", label="Data last fetch",     value=self.runtime.last_data_fetch or "Never"},
        {icon="🕐", label="Config last sync",    value=self.store.ams_configuration_last_sync or "Never"},
        {icon="✅", label="Data status",         value=self.runtime.last_data_fetch_status or "No data yet"},
        {icon="🔒", label="Security",            value=fmt_security_mode(self.store.ams_sysinfo_security)},
        {icon="🌐", label="AMS host",            value=ams_base_url},
        {icon="🔐", label="HTTP Auth",           value=get_ams_auth_status_text(self)},
        {icon="🛜", label="Device IP",           value=fmt_text(self.store.ams_sysinfo_device_ip)},
        {icon="🧭", label="Hostname",            value=fmt_text(self.store.ams_sysinfo_hostname)},
        {icon="⚠️", label="Errors",              value=tostring(errors), vc=err_color},
        {icon="🌡️", label="Temperature",         value=fmt_num(self.runtime.ams_temperature, "C", 1)},
        {icon="⏳", label="Uptime (hours)",      value=fmt_uptime_hours(self.runtime.ams_uptime_seconds)},
        {icon="🕰️", label="Clock",               value=fmt_clock(self.runtime.ams_clock)},
        {icon="💾", label="Free memory",         value=fmt_num(self.runtime.ams_free_memory_bytes, "bytes")},
        {icon="🧠", label="Firmware",            value=fmt_text(self.store.ams_sysinfo_version)},
        {icon="🚀", label="Upgrade",             value=firmware_status()},
        {icon="⚙️", label="Chip / CPU",          value=chip_value},
        {icon="🧬", label="MAC",                 value=fmt_text(self.store.ams_sysinfo_mac)},
        {icon="🔢", label="Meter type",          value=fmt_meter_type(self.store.ams_sysinfo_meter_mfg or self.runtime.ams_meter_type)},
        {icon="🔌", label="Grid System",          value=fmt_distribution_system(self.runtime.ams_distribution_system)},
        {icon="🛡️", label="Main Fuse",           value=fmt_num(self.runtime.ams_main_fuse_size, "A")},
        {icon="💹", label="Price Region",        value=fmt_price_region(self.store.ams_price_region_code)},
        {icon="💹", label="Price Interval",      value=fmt_price_interval(self.store.ams_price_interval_minutes)},
        {icon="📥", label="Max Import Power",    value=fmt_num(self.runtime.ams_import_max_power, "W")},
        {icon="📤", label="Max Export Power",    value=fmt_num(self.runtime.ams_export_max_power, "W")},
        {icon="🧮", label="Multiplier Ampere",   value=fmt_multiplier(self.store.ams_multiplier_ampere)},
        {icon="🧮", label="Multiplier Voltage",  value=fmt_multiplier(self.store.ams_multiplier_voltage)},
        {icon="🧮", label="Multiplier Energy",   value=fmt_multiplier(self.store.ams_multiplier_energy)},
        {icon="🧮", label="Multiplier Watt",     value=fmt_multiplier(self.store.ams_multiplier_watt)},
        {icon="🏷️", label="Model",               value=fmt_text(self.store.ams_sysinfo_meter_model)},
        {icon="🆔", label="Meter Serial Nr",     value=fmt_text(self.store.ams_sysinfo_meter_id)},
    }

    self:updateView("info_ams", "text", with_top_divider(build_card("📡", "Connection", rows)))
end

function Info()
-- Helper: value+unit string for a sensor uid
local function sv(uid)
    local s = Child_table[uid]
    if not s or not s.store then return "-" end
    local v = s.store.value
    if v == nil or v == "" then return "-" end
    return tostring(v) .. " " .. (s.store.unit or "")
end

local function sv_override(uid, value)
    local s = Child_table[uid]
    if not s or not s.store then return "-" end
    if value == nil or value == "" then return "-" end
    return tostring(value) .. " " .. (s.store.unit or "")
end

local function get_online_status()
    local stored = Child_table["s49"] and Child_table["s49"].store and Child_table["s49"].store.value
    if type(stored) == "boolean" then
        return stored
    end
    return self.runtime.ams_online ~= false
end

local function phase_rows(phase_key, voltage_uid, amperage_uid, active_uid, apparent_uid, reactive_uid, pf_uid)
    local snapshot = self.runtime.phase_power_factor_snapshots and self.runtime.phase_power_factor_snapshots[phase_key]
    local calculated = (self.runtime.phase_power_factor_sources and self.runtime.phase_power_factor_sources[phase_key] == "calculated")
        and type(snapshot) == "table"
    local suffix = calculated and "(c)" or ""

    return {
        {icon="🔌", label="Voltage",                value=sv(voltage_uid)},
        {icon="〰️", label="Amperage",               value=sv(amperage_uid)},
        {icon="⚡", label="Active Power" .. suffix,   value=calculated and sv_override(active_uid, snapshot.active) or sv(active_uid)},
        {icon="🔺", label="Apparent Power" .. suffix, value=calculated and sv_override(apparent_uid, snapshot.apparent) or sv(apparent_uid)},
        {icon="🔁", label="Reactive Power" .. suffix, value=calculated and sv_override(reactive_uid, snapshot.reactive) or sv(reactive_uid)},
        {icon="📊", label="Power Factor",           value=calculated and sv_override(pf_uid, snapshot.pf) or sv(pf_uid)},
    }
end

local function build_minmax_rows()
    local state = load_minmax_state(self)

    local function fmt_stat(value, decimals, unit)
        local numeric = tonumber(value)
        if numeric == nil then return "-" end
        return string.format("%." .. tostring(decimals) .. "f %s", numeric, unit)
    end

    local function fmt_timestamp(ts)
        local numeric = tonumber(ts)
        if numeric == nil or numeric <= 0 then return "-" end
        return "📅 " .. os.date("%d/%m/%y", numeric) .. "  🕐" .. os.date("%H:%M", numeric)
    end

    local rows = {}
    local function add_stat(stat_icon, stat_label, stat_value, stat_ts)
        rows[#rows+1] = {
            icon = stat_icon,
            label = stat_label,
            value = stat_value,
        }
        rows[#rows+1] = {
            icon = "🕒",
            label = "Timestamp",
            value = fmt_timestamp(stat_ts),
            vc = config.colors.color4,
        }
    end

    add_stat("📉", "L1 Volt Min",      fmt_stat(state.voltage_min.l1, 1, "V"),      state.voltage_min_ts.l1)
    add_stat("📉", "L2 Volt Min",      fmt_stat(state.voltage_min.l2, 1, "V"),      state.voltage_min_ts.l2)
    add_stat("📉", "L3 Volt Min",      fmt_stat(state.voltage_min.l3, 1, "V"),      state.voltage_min_ts.l3)
    add_stat("📈", "L1 Volt Max",      fmt_stat(state.voltage_max.l1, 1, "V"),      state.voltage_max_ts.l1)
    add_stat("📈", "L2 Volt Max",      fmt_stat(state.voltage_max.l2, 1, "V"),      state.voltage_max_ts.l2)
    add_stat("📈", "L3 Volt Max",      fmt_stat(state.voltage_max.l3, 1, "V"),      state.voltage_max_ts.l3)
    add_stat("〰️", "L1 Amp Max",       fmt_stat(state.amp_max.l1, 2, "A"),          state.amp_max_ts.l1)
    add_stat("〰️", "L2 Amp Max",       fmt_stat(state.amp_max.l2, 2, "A"),          state.amp_max_ts.l2)
    add_stat("〰️", "L3 Amp Max",       fmt_stat(state.amp_max.l3, 2, "A"),          state.amp_max_ts.l3)
    add_stat("⚡", "W Max Peak IMP",   fmt_stat(state.watt_import_peak, 0, "W"),    state.watt_import_peak_ts)
    add_stat("⚡", "W Max Peak EXP",   fmt_stat(state.watt_export_peak, 0, "W"),    state.watt_export_peak_ts)
    add_stat("🕐", "kWh Max Hour IMP", fmt_stat(state.hour_import_peak, 2, "kWh"),  state.hour_import_peak_ts)
    add_stat("🕐", "kWh Max Hour EXP", fmt_stat(state.hour_export_peak, 2, "kWh"),  state.hour_export_peak_ts)

    return rows
end

local parts = {}
local online = get_online_status()
local online_text = online and "Online" or "Offline"
local online_color = online and config.colors.color2 or "#ff3b30"

parts[#parts+1] = build_card("📶", "AMS Status", {
    {icon="📡", label="Status", value=online_text, vc=online_color},
})
parts[#parts+1] = build_divider()

parts[#parts+1] = build_card("⚡", "Active Power", {
    {icon="➕", label="Import",        value=sv("s1")},
    {icon="➖", label="Export",        value=sv("s2")},
    {icon="↔️", label="Import/Export", value=sv("s3")},
})
parts[#parts+1] = build_divider()

parts[#parts+1] = build_card("🔁", "Reactive Power", {
    {icon="➕", label="Import", value=sv("s4")},
    {icon="➖", label="Export", value=sv("s5")},
    {icon="📊", label="Power Factor", value=sv("s41")},
})
parts[#parts+1] = build_divider()

parts[#parts+1] = build_card("🔋", "Accumulated Energy", {
    {icon="➕", label="Import",           value=sv("s6")},
    {icon="➖", label="Export",           value=sv("s7")},
    {icon="➕", label="Reactive import",  value=sv("s8")},
    {icon="➖", label="Reactive export",  value=sv("s9")},
    {icon="🕐", label="Import This Hour", value=sv("s25")},
    {icon="🕑", label="Import Last Hour", value=sv("s26")},
    {icon="📤", label="This Hour Export", value=sv("s36")},
    {icon="💸", label="This Hour Cost",   value=sv("s35")},
    {icon="💰", label="This Hour Income", value=sv("s37")},
    {icon="📅", label="Import Today",     value=sv("s27")},
    {icon="📆", label="Import Yesterday", value=sv("s28")},
    {icon="📤", label="Export Today",     value=sv("s39")},
    {icon="💸", label="Cost Today",       value=sv("s38")},
    {icon="💰", label="Income Today",     value=sv("s40")},
    {icon="🗓️", label="Import This Month", value=sv("s45")},
    {icon="📤", label="Export This Month", value=sv("s47")},
    {icon="💸", label="Cost This Month",   value=sv("s46")},
    {icon="💰", label="Income This Month", value=sv("s48")},
})
parts[#parts+1] = build_divider()

parts[#parts+1] = build_card("1️⃣", "Phase L1", phase_rows("l1", "s10", "s11", "s12", "s42", "s13", "s14"))
parts[#parts+1] = build_divider()

parts[#parts+1] = build_card("2️⃣", "Phase L2", phase_rows("l2", "s15", "s16", "s17", "s43", "s18", "s19"))
parts[#parts+1] = build_divider()

parts[#parts+1] = build_card("3️⃣", "Phase L3", phase_rows("l3", "s20", "s21", "s22", "s44", "s23", "s24"))
parts[#parts+1] = build_divider()

parts[#parts+1] = build_card("📏", "Min/Max Values", build_minmax_rows())

self:updateView("Info", "text", with_top_divider(table.concat(parts)))
end

maybe_refresh_live_ui_cards(self, true)
UpdateInfoUrl()
UpdateInfoPrice()
UpdateInfoHours()
UpdateInfoDays()
UpdateInfoMonths()
UpdateInfoTariff()
maybe_sync_sysinfo(self, true)
maybe_sync_configuration(self, true)
maybe_sync_energyprice(self, true)
maybe_sync_dayplot(self, true)
maybe_sync_monthplot(self, true)
maybe_sync_tariff(self, true)
start_hourly_sync_schedule(self)



-------------------------------------------------------------------------------------------------------------------------------
-------------------------------------------------------------------------------------------------------------------------------

-- Polling is handled by setInterval(get_data_update_interval_ms()) in onInit.






-------------------------------------------------------------------------------------------------------------------------------
-------------------------------------------------------------------------------------------------------------------------------





---------------------------------------------------------------------------------------------------------------------
---------------------------------------------------------------------------------------------------------------------
---------------------------------------------------------------------------------------------------------------------
---------------------------------------------------------------------------------------------------------------------


---------------------------------------------------------------------------------------------------------------------
---------------------------------------------------------------------------------------------------------------------

















-------------------------------------------------------------------------------------------------------------------------------
-------------------------------------------------------------------------------------------------------------------------------
-------------------------------------------------------------------------------------------------------------------------------
-------------------------------------------------------------------------------------------------------------------------------
-------------------------------------------------------------------------------------------------------------------------------
-------------------------------------------------------------------------------------------------------------------------------
-------------------------------------------------------------------------------------------------------------------------------
-------------------------------------------------------------------------------------------------------------------------------
-------------------------------------------------------------------------------------------------------------------------------
-------------------------------------------------------------------------------------------------------------------------------
local c0,t0 = os.clock(),os.time()
local gc_collect_interval = math.max(60, tonumber(config.gc_collect_interval) or (5 * 60))
local gc_collect_threshold_kb = math.max(0, tonumber(config.gc_collect_threshold_kb) or 3000)
local initial_kbc = collectgarbage("count")
collectgarbage("collect")
local initial_kb = collectgarbage("count")
local last_gc_collect_ts = os.time()
local kb = initial_kb
local cpp = 0.0001
local kbc = initial_kbc

-------------------------------------------------------------------------------------------------------------------------------
-------------------------------------------------------------------------------------------------------------------------------
local function UpdateErrorStatus()
    local parts = {}

    -- Spacing so this label sits clear of the one above it
    parts[#parts+1] = string.rep("<br>", 15)

    -- System status card (live CPU / memory from the GC interval)
    parts[#parts+1] = build_card("💻", "System Status", {
        {icon="💾", label="Memory (last GC)",   value=string.format("%.2f",  tonumber(kb)  or 0) .. " kB"},
        {icon="💾", label="Memory (current)",   value=string.format("%.2f",  tonumber(kbc) or 0) .. " kB"},
        {icon="🔥", label="QA CPU usage",        value=string.format("%.4f", tonumber(cpp) or 0) .. " %"},
    })
    parts[#parts+1] = build_divider()

    -- Last-10-errors card
    local log = {}
    local lj = self.store.error_log_json
    if lj and lj ~= "" then
        local ok, t = pcall(json.decode, lj)
        if ok and type(t) == "table" then log = t end
    end

    local rows = {}
    if #log == 0 then
        rows[1] = {icon="✅", label="No errors logged", value=""}
    else
        for i = #log, 1, -1 do   -- newest first
            rows[#rows+1] = {icon="🔴", label=log[i].ts, value=log[i].msg}
        end
    end
    parts[#parts+1] = build_card("⚠️", "Error Log (last 10)", rows)

    self:updateView("error_status", "text", with_top_divider(table.concat(parts)))
end

-- Assign the forward-declared logError now that UpdateErrorStatus and kb/kbc/cpp exist
logError = function(msg)
    local log = {}
    local lj = self.store.error_log_json
    if lj and lj ~= "" then
        local ok, t = pcall(json.decode, lj)
        if ok and type(t) == "table" then log = t end
    end
    table.insert(log, {ts = os.date("%m-%d %H:%M:%S"), msg = tostring(msg)})
    while #log > 10 do table.remove(log, 1) end
    self.store.error_log_json = json.encode(log)
    UpdateErrorStatus()
end
-------------------------------------------------------------------------------------------------------------------------------
-------------------------------------------------------------------------------------------------------------------------------

setInterval(function()
    kbc = collectgarbage("count")
    local now = os.time()
    local should_collect = (now - last_gc_collect_ts) >= gc_collect_interval
        or kbc >= gc_collect_threshold_kb

    if should_collect then
        collectgarbage("collect")
        kb = collectgarbage("count")
        last_gc_collect_ts = now
    end

local c1,T1=os.clock(),os.time()
local elapsed = math.max(1, T1 - t0)
cpp = ((c1-c0) / elapsed) * 100
c0,t0=c1,T1
Setup_manual()
-- kb is Kb used by the Lua interpreter
-- cpp is the approximate percent of CPU time used by this QA over the last interval
end, refresh_mem *1000)
-------------------------------------------------------------------------------------------------------------------------------
-------------------------------------------------------------------------------------------------------------------------------
function Setup_manual()
local kb_num = tonumber(kb) or 0
local kb_val = string.format("%.2f", kb_num)
local kb_max = tonumber(self.runtime.kb_val_max) or kb_num
if kb_num > kb_max then
self.runtime.kb_val_max = kb_num
kb_max = kb_num
end
local kb_max_val = string.format("%.2f", kb_max)

local kbc_num = tonumber(kbc) or 0
local kbc_val = string.format("%.2f", kbc_num)
local kbc_max = tonumber(self.runtime.kbc_val_max) or kbc_num
if kbc_num > kbc_max then
self.runtime.kbc_val_max = kbc_num
kbc_max = kbc_num
end
local kbc_max_val = string.format("%.2f", kbc_max)

local cpp_num = tonumber(cpp) or 0
local cpp_val = string.format("%.4f", cpp_num) 
local cpp_max = tonumber(self.runtime.cpp_val_max) or cpp_num
if cpp_num > cpp_max then
self.runtime.cpp_val_max = cpp_num
cpp_max = cpp_num
end
local cpp_max_val = string.format("%.4f", cpp_max)



local content = build_card("🖥️", "System", {
    {icon="⏱️", label="Updates every",    value=refresh_mem .. " sec"},
    {icon="💾", label="Memory last GC",   value=kb_val      .. " kB"},
    {icon="💾", label="Memory last GC max", value=kb_max_val  .. " kB"},
    {icon="💾", label="Memory current",   value=kbc_val     .. " kB"},
    {icon="💾", label="Memory current max", value=kbc_max_val .. " kB"},
    {icon="🔥", label="QA CPU usage",     value=cpp_val     .. " %"},
    {icon="🔥", label="QA CPU max",       value=cpp_max_val .. " %"},
    {icon="🕐", label="Started",          value=config.start_date},
})

self:updateView("Setup_manual", "text", with_top_divider(content))
UpdateErrorStatus()
end
---------------------------------------------------------------------------------------------------------------------
---------------------------------------------------------------------------------------------------------------------
Setup_manual()
---------------------------------------------------------------------------------------------------------------------
---------------------------------------------------------------------------------------------------------------------
hub.setTimeout(15*1000, function()  
Setup_manual()
end)
---------------------------------------------------------------------------------------------------------------------
---------------------------------------------------------------------------------------------------------------------
---@diagnostic disable-next-line
function QuickApp:t1(_)
self:warning("Reading /configuration.json to console")
Http_get_configuration(true)
end
-------------------------------
---@diagnostic disable-next-line
function QuickApp:t2(_)
self:warning("Reading AMS JSON endpoints to console")
for _, path in ipairs({
    "/data.json",
    "/sysinfo.json",
    "/configuration.json",
    "/energyprice.json",
    "/priceconfig.json",
    "/dayplot.json",
    "/monthplot.json",
    "/tariff.json",
}) do
    Http_get_json_debug(path)
end
end
---------------------------------------------------------------------------------------------------------------------
---------------------------------------------------------------------------------------------------------------------
---@diagnostic disable-next-line
function QuickApp:Restart(args)
self:updateView("Restart", "value", "true")
Restart()
end
-------------------------------
function Restart()
hub.setTimeout(200, function()  
self:updateView("Restart", "value", "false")
end)
hub.setTimeout(2*1000, function()  
plugin.restart()
end)
end
---------------------------------------------------------------------------------------------------------------------
---------------------------------------------------------------------------------------------------------------------
------update label for lines between the "groups of functions in the QA view"  
local infoline = "<hr width=400px color="..config.colors.color4.." size=2px >"
self:updateView("infoline1", "text",infoline.."")
self:updateView("infoline2", "text",infoline.."")
self:updateView("infoline3", "text",infoline.."")
self:updateView("infoline4", "text",infoline.."")
self:updateView("infoline5", "text",infoline.."")
self:updateView("infoline6", "text",infoline.."")
self:updateView("infoline7", "text",infoline.."")
self:updateView("infoline8", "text",infoline.."")
self:updateView("infoline9", "text",infoline.."")
self:updateView("infoline10", "text",infoline.."")
self:updateView("infoline11", "text",infoline.."")
self:updateView("infoline12", "text",infoline.."")
self:updateView("infoline13", "text",infoline.."")
self:updateView("infoline14", "text",infoline.."")
self:updateView("infoline15", "text",infoline.."")
self:updateView("infoline16", "text",infoline.."")
self:updateView("infoline17", "text",infoline.."")
self:updateView("infoline18", "text",infoline.."")
self:updateView("infoline19", "text",infoline.."")
self:updateView("infoline20", "text",infoline.."")

self:updateView("s10", "text","Restart Done")
hub.setTimeout(5*1000, function()  
self:updateView("s10", "text","")
end)


---------------------------------------------------------------------------------------------------------------------
---------------------------------------------------------------------------------------------------------------------
---startup timer. 
self:debug("ID:"..self.id.." Name; "..self.name.." has started in the room: "..self_room_name.."")
local endtime = os.clock()
print(self.id.." Used: ", endtime-config.start_time,"sec to start")


end ------function QuickApp:onInit()
-------------------------------------------------------------------------------------------------------------------------------
-------------------------------------------------------------------------------------------------------------------------------
