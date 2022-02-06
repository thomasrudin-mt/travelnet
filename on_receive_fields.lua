local S = minetest.get_translator("travelnet")

local player_formspec_data = travelnet.player_formspec_data

local function on_receive_fields_internal(pos, fields, player)
	if not pos then
		return
	end

	local meta = minetest.get_meta(pos)
	local name = player:get_player_name()

	-- the player wants to quit/exit the formspec; do not save/update anything
	if fields and fields.station_exit and fields.station_exit ~= "" then
		return
	end

	local owner_name      = meta:get_string("owner")
	local station_network = meta:get_string("station_network")
	local station_name    = meta:get_string("station_name")

	-- if there is something wrong with the data
	if not owner_name or not station_network or not station_name then
		minetest.chat_send_player(name, S("Error") .. ": " ..
				S("There is something wrong with the configuration of this station.") ..
					" DEBUG DATA: owner: " .. (owner_name or "?") ..
					" station_name: " .. (station_name or "?") ..
					" station_network: " .. (station_network or "?") .. "."
		)
		print(
			"ERROR: The travelnet at " .. minetest.pos_to_string(pos) .. " has a problem: " ..
			" DATA: owner: " .. (owner_name or "?") ..
			" station_name: " .. (station_name or "?") ..
			" station_network: " .. (station_network or "?") .. "."
		)
		return
	end

	local node = minetest.get_node(pos)

	if (travelnet.MAX_STATIONS_PER_NETWORK == 0 or travelnet.MAX_STATIONS_PER_NETWORK > 24)
		and fields.page_number
		and (
			fields.next_page
			or fields.prev_page
			or fields.last_page
			or fields.first_page
		)
	then
		local page = 1
		local network = travelnet.get_network(owner_name, station_network)
		local station_count = 0
		for _ in pairs(network) do
			station_count = station_count+1
		end
		local page_size = 7*3
		local pages = math.ceil(station_count/page_size)

		if fields.last_page then
			page = pages
		else
			local current_page = tonumber(fields.page_number)
			if current_page then
				if fields.next_page then
					page = math.min(current_page+1, pages)
				elseif fields.prev_page then
					page = math.max(current_page-1, 1)
				end
			end
		end
		travelnet.page_formspec(pos, name, page)
	end

	-- the player wants to remove the station
	if fields.station_dig or fields.station_edit then
		local description = travelnet.node_description(pos)

		if not description then
			minetest.chat_send_player(name, "Error: Unknown node.")
			return
		end

		-- players with travelnet_remove priv can dig the station
		if	    not minetest.check_player_privs(name, { travelnet_remove=true })
			-- the function travelnet.allow_dig(..) may allow additional digging
			and not travelnet.allow_dig(name, owner_name, station_network, pos)
			-- the owner can remove the station
			and owner_name ~= name
			-- stations without owner can be removed/edited by anybody
			and owner_name ~= ""
		then
			minetest.chat_send_player(name,
				S("This @1 belongs to @2. You can't remove it.", description, owner_name)
			)
			return
		end

		-- abort if protected by another mod
		if	minetest.is_protected(pos, name)
			and not minetest.check_player_privs(name, { protection_bypass=true })
		then
			minetest.record_protection_violation(pos, name)
			return
		end

		if fields.station_dig then
			-- remove station
			local player_inventory = player:get_inventory()
			if not player_inventory:room_for_item("main", node.name) then
				minetest.chat_send_player(name, S("You do not have enough room in your inventory."))
				return
			end

			-- give the player the box
			player_inventory:add_item("main", node.name)
			-- remove the box from the data structure
			travelnet.remove_box(pos, nil, meta:to_table(), player)
			-- remove the node as such
			minetest.remove_node(pos)
		else
			-- edit station
			travelnet.edit_formspec(pos, meta, name)
		end
		return
	end

	-- if the box has not been configured yet
	if station_network == "" then
		travelnet.add_target(fields.station_name, fields.station_network, pos, name, meta, fields.owner)
		return
	end

	-- save pressed after editing
	if fields.station_set then
		travelnet.edit_box(pos, fields, meta, name)
	end

	if fields.open_door then
		travelnet.open_close_door(pos, player, "toggle")
		return
	end

	-- the owner or players with the travelnet_attach priv can move stations up or down in the list
	if fields.move_up or fields.move_down then
		travelnet.change_order(pos, name, fields)
		return
	end

	if not fields.target then
		minetest.chat_send_player(name, S("Please click on the target you want to travel to."))
		return
	end

	local network = travelnet.get_network(owner_name, station_network)

	if not network then
		travelnet.add_target(station_name, station_network, pos, owner_name, meta, owner_name)
		return
	end

	if node ~= nil and travelnet.is_elevator(node.name) then
		for k,_ in pairs(network) do
			if network[k].nr == fields.target then
				fields.target = k
				-- break ??
			end
		end
	end

	local target_station = network[fields.target]

	-- if the target station is gone
	if not target_station then
		minetest.chat_send_player(name,
				S("Station '@1' does not exist (anymore?)" ..
					" " .. "on this network.", fields.target or "?")
		)
		travelnet.page_formspec(pos, player_name)
		return
	end


	if not travelnet.allow_travel(name, owner_name, station_network, station_name, fields.target) then
		return
	end
	minetest.chat_send_player(name, S("Initiating transfer to station '@1'.", fields.target or "?"))

	if travelnet.travelnet_sound_enabled then
		if travelnet.is_elevator(node.name) then
			minetest.sound_play("travelnet_bell", {
				pos = pos,
				gain = 0.75,
				max_hear_distance = 10
			})
		else
			minetest.sound_play("travelnet_travel", {
				pos = pos,
				gain = 0.75,
				max_hear_distance = 10
			})
		end
	end

	if travelnet.travelnet_effect_enabled then
		minetest.add_entity(vector.add(pos, { x=0, y=0.5, z=0 }), "travelnet:effect")  -- it self-destructs after 20 turns
	end

	-- close the doors at the sending station
	travelnet.open_close_door(pos, player, "close")

	-- transport the player to the target location

	-- may be 0.0 for some versions of MT 5 player model
	local player_model_bottom = tonumber(minetest.settings:get("player_model_bottom")) or -.5
	local player_model_vec = vector.new(0, player_model_bottom, 0)
	local target_pos = target_station.pos

	local top_pos = vector.add(pos, { x=0, y=1, z=0 })
	local top_node = minetest.get_node(top_pos)
	if top_node.name ~= "travelnet:hidden_top" then
		local def = minetest.registered_nodes[top_node.name]
		if def and def.buildable_to then
			minetest.set_node(top_pos, { name="travelnet:hidden_top" })
		end
	end

	minetest.load_area(target_pos)

	local tnode = minetest.get_node(target_pos)
	-- check if the box has at the other end has been removed.
	if minetest.get_item_group(tnode.name, "travelnet") == 0 and minetest.get_item_group(tnode.name, "elevator") == 0 then
		-- provide information necessary to identify the removed box
		local oldmetadata = {
			fields = {
				owner           = owner_name,
				station_name    = fields.target,
				station_network = station_network
			}
		}

		travelnet.remove_box(target_pos, nil, oldmetadata, player)
	else
		player:move_to(vector.add(target_pos, player_model_vec), false)
		travelnet.rotate_player(target_pos, player)
	end

end

function travelnet.on_receive_fields(pos, _, fields, player)
	local name = player:get_player_name()
	player_formspec_data[name] = player_formspec_data[name] or {}
	if pos then
		player_formspec_data[name].pos = pos
	else
		pos = player_formspec_data[name].pos
	end

	player_formspec_data[name].wait_mode = true
	on_receive_fields_internal(pos, fields, player)

	local closed = not travelnet.show_formspec(name)
	if fields.quit or closed then
		player_formspec_data[name] = nil
	else
		player_formspec_data[name].wait_mode = nil
	end
end
