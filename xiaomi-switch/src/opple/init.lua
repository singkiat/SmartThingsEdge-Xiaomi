local zcl_clusters = require "st.zigbee.zcl.clusters"
local capabilities = require "st.capabilities"

local log = require "log"
local utils = require "utils"
local data_types = require "st.zigbee.data_types"
local cluster_base = require "st.zigbee.cluster_base"
local xiaomi_utils = require "xiaomi_utils"
local zigbee_utils = require "zigbee_utils"
local device_management = require "st.zigbee.device_management"

local OnOff = zcl_clusters.OnOff
local Level = zcl_clusters.Level
local Scenes = zcl_clusters.Scenes
local ColorControl = zcl_clusters.ColorControl
local PowerConfiguration = zcl_clusters.PowerConfiguration
local Groups = zcl_clusters.Groups

local OPPLE_FINGERPRINTS = {
    { model = "^lumi.switch...aeu1" },
    { model = "^lumi.remote.b.8" },
    { model = "^lumi.switch.b.lc04" },
    { model = "^lumi.switch..3acn." },
    { model = "^lumi.switch.acn058" },
    { model = "^lumi.switch.acn059" },
}

local is_opple = function(opts, driver, device)
    for _, fingerprint in ipairs(OPPLE_FINGERPRINTS) do
        if (device:get_model():find(fingerprint.model) ~= nil) then
            return true
        end
    end
    return false
end

local is_z1_pro = function(device)
    local deviceModel = device:get_model()
    return deviceModel == "lumi.switch.acn058" or deviceModel == "lumi.switch.acn059"
end

local send_opple_message = function (device, attr, payload, endpoint)
    local message = cluster_base.write_attribute(device, data_types.ClusterId(xiaomi_utils.OppleCluster), data_types.AttributeId(attr), payload)
    message.body.zcl_header.frame_ctrl:set_mfg_specific()
    message.body.zcl_header.mfg_code = data_types.validate_or_build_type(0x115F, data_types.Uint16, "mfg_code")
    if (endpoint ~= nil) then
        message:to_endpoint(endpoint)
    end
    device:send(message)
end

local do_refresh = function(self, device)
    device:send(PowerConfiguration.attributes.BatteryVoltage:read(device))

    if is_z1_pro(device) then
        device:send(cluster_base.read_manufacturer_specific_attribute(device, xiaomi_utils.OppleCluster, 0x0286, 0x115F))
        device:send(cluster_base.read_manufacturer_specific_attribute(device, xiaomi_utils.OppleCluster, 0x00F7, 0x115F))
    else
        device:send(cluster_base.read_manufacturer_specific_attribute(device, xiaomi_utils.OppleCluster, 0x0009, 0x115F))
        device:send(cluster_base.read_manufacturer_specific_attribute(device, xiaomi_utils.OppleCluster, 0x0125, 0x115F))
    end
    
    zigbee_utils.print_clusters(device)
    device:send(Groups.server.commands.GetGroupMembership(device, {}))
    device:send( zigbee_utils.build_read_binding_table(device) )
end


local do_configure = function(self, device)
    local operationMode = device.preferences.operationMode or 1
    operationMode = tonumber(operationMode)

    log.info("Configuring Opple device " .. tostring(operationMode))

    data_types.id_to_name_map[0xE10] = "OctetString"
    data_types.name_to_id_map["SpecialType"] = 0xE10
    
    if is_z1_pro(device) then
        if operationMode == 1 then
            send_opple_message(device, 0x0286, data_types.Uint8(0x02), 0x01)
        end
    else
        send_opple_message(device, 0x0009, data_types.Uint8(operationMode), 0x01)

        if operationMode == 1 then
            send_opple_message(device, 0x0125, data_types.Uint8(0x02), 0x01)
        end
    end
    
    if operationMode == 0 then      -- light group binding
        local group = device.preferences.group or 1
        group = tonumber(group)

        --device:send(zigbee_utils.build_bind_request(device, OnOff.ID, group))
        device:send(zigbee_utils.build_bind_request(device, Level.ID, group))
        device:send(zigbee_utils.build_bind_request(device, Scenes.ID, group)) 
        device:send(zigbee_utils.build_bind_request(device, ColorControl.ID, group))
        device:send(zigbee_utils.build_read_binding_table(device)) 
    end

    if device:supports_capability(capabilities.battery, "main") then
        device:send(PowerConfiguration.attributes.BatteryPercentageRemaining:configure_reporting(device, 30, 21600, 1))
        device:send(PowerConfiguration.attributes.BatteryVoltage:configure_reporting(device, 30, 21600, 1))
    end
end

local function info_changed(driver, device, event, args)
    for id, value in pairs(device.preferences) do
      if args.old_st_store.preferences[id] ~= value then
        local data = device.preferences[id]
        data = tonumber(data) or data

        local attr
        local payload 
        local endpoint
        
        if id == "operationMode" then
            do_configure(driver, device)
        elseif id == "group" then
            device:send(zigbee_utils.build_bind_request(device, OnOff.ID, data))
            device:send(zigbee_utils.build_bind_request(device, Level.ID, data))
            device:send(zigbee_utils.build_bind_request(device, Scenes.ID, data))
            device:send(zigbee_utils.build_bind_request(device, ColorControl.ID, data))
        elseif id == "stse.restorePowerState" then
            payload = data_types.validate_or_build_type(data, data_types.Boolean, id)
            attr = 0x0201
        elseif id == "stse.turnOffIndicatorLight" then
            payload = data_types.validate_or_build_type(data, data_types.Boolean, id)
            attr = 0x0203
        elseif id == "stse.changeToWirelessSwitch" then
            attr = 0x0200
            endpoint = 1
            payload = data_types.validate_or_build_type(data and 0 or 1, data_types.Uint8, id)
        elseif id == "button1" then
            attr = 0x0200
            endpoint = 1
            payload = data_types.validate_or_build_type(data<0xF0 and 1 or 0, data_types.Uint8, id)
        elseif id == "button2" then
            attr = 0x0200
            endpoint = 2
            payload = data_types.validate_or_build_type(data<0xF0 and 1 or 0, data_types.Uint8, id)
        elseif id == "button3" then
            attr = 0x0200
            endpoint = 3
            payload = data_types.validate_or_build_type(data<0xF0 and 1 or 0, data_types.Uint8, id)
        end

        if attr then
            send_opple_message(device, attr, payload, endpoint)
        end
      end
    end
end


local function attr_operation_mode_handler(driver, device, value, zb_rx)
    log.info("attr_operation_mode_handler " .. tostring(value))
    device:set_field("operationMode", value.value, {persist = true})
end

local function attr_multi_click_handler(driver, device, value, zb_rx)
    local attr_id = zb_rx.body.zcl_body.attr_records[1].attr_id.value
    device:set_field("multiClickMode_" .. string.format("%04X", attr_id), value.value, {persist = true})
end

local function attr_decoupling_handler(driver, device, value, zb_rx)
    local endpoint = zb_rx.address_header.src_endpoint.value
    device:set_field("decouplingMode_EP" .. endpoint, value.value, {persist = true})
end


local function attr_slider_handler(driver, device, value, zb_rx)
    local slider_mapping = {
        [1] = capabilities.button.button.pushed,
        [2] = capabilities.button.button.pushed_2x,
        [3] = capabilities.button.button.held,
        [4] = capabilities.button.button.up,
        [5] = capabilities.button.button.down,
    }
    
    local button_event = slider_mapping[value.value]
    if button_event then
        device:emit_component_event(device.profile.components.slider, button_event({state_change = true}))
    end
end


local switch_handler = {
    NAME = "Zigbee3 Aqara/Opple",
    capability_handlers = {
        [capabilities.refresh.ID] = {
          [capabilities.refresh.commands.refresh.NAME] = do_refresh,
        }
    },
    zigbee_handlers = {
        attr = {
            [xiaomi_utils.OppleCluster] = {
                [0x0009] = attr_operation_mode_handler,
                [0x0125] = attr_multi_click_handler,
                [0x0200] = attr_decoupling_handler,
                [0x0286] = attr_multi_click_handler,
                [0x028C] = attr_slider_handler,
                [0x00F7] = xiaomi_utils.handler
            },
            [PowerConfiguration.ID] = {
                [PowerConfiguration.attributes.BatteryVoltage.ID] = xiaomi_utils.emit_battery_event,
            }
        }
    },
    lifecycle_handlers = {
        infoChanged = info_changed,
        doConfigure = do_configure,
    },
    can_handle = is_opple
}

return switch_handler
