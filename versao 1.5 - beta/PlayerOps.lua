--[[
    PlayerOps v1.5 — MoonLoader SA-MP
    Comandos: /playerops | /gg | /playeropslixao
    Silencioso (sem mensagens no chat).
]]

script_name("PlayerOps")
script_author("Grok")
script_version("1.5")
script_description("PlayerOps - Helpers BNS")
script_properties('work-in-pause')

require "lib.moonloader"
local sampev = require "lib.samp.events"
local imgui  = require "mimgui"
local ffi    = require "ffi"

local VK_Y = 0x59

-- Armas que ficam apos /kitvip (resto = /largararma)
local KEEP_WEAPONS = {
    [4]  = true, -- faca
    [24] = true, -- desert eagle
    [31] = true, -- m4
    [34] = true, -- sniper
}

local CONFIG = {
    checkInterval    = 300,
    delayAposKit     = 2000,
    distMaxDroga     = 5.0,
    intervaloColeta  = 15000,
    dialogTimeoutMs  = 4000,
    cooldownRoubo    = 5 * 60 * 1000,
    distMaxRoubo     = 5.0,
    maxDistance      = 25.0,
    buyDistance      = 14.5,
    sellDistance     = 7.0,
    buyCooldown      = 1200,
    serviceCooldown  = 5000,
    lixeiraDistance  = 3.5,
    lixaoDistance    = 10.0,
    maxColetas       = 5,
    lixeiraCooldown  = 800,
    entregarCooldown = 3000,
}

local state = {
    menuOpen = imgui.new.bool(false),
    autoDroga     = imgui.new.bool(false),
    autoRoubo     = imgui.new.bool(false),
    autoTrabalho  = imgui.new.bool(false),
    autoLargarArma = imgui.new.bool(false),
    ggranaProcessando = false,
    propDepositCustom = imgui.new.char[32](""),
    propPrecoCustom   = imgui.new.char[32](""),
    pontoDrogaX = nil, pontoDrogaY = nil, pontoDrogaZ = nil,
    coletando = false,
    emCooldownDroga = false,
    tempoCooldownDroga = 0,
    ultimaColeta = 0,
    lastDialogId = nil,
    lastDialogStyle = nil,
    waitingDialogFor = nil,
    ultimoUsoRoubo = 0,
    job = 1,
    cargoType = 1,
    targetId = imgui.new.char[32]("1"),
    lastAction = 0,
    statusText = "Aguardando...",
    inService = false,
    lastServiceTry = 0,
    cargoFull = false,
    justBought = false,
    lastVehicleModel = 0,
    currentCargo = 0,
    lastBuyAmount = 0,
    coletas = 0,
    lixeiroFull = false,
    lastLixeiraAction = 0,
    lastEntregar = 0,
    lixaoPos = { x = 2178.3, y = -1970.1, z = 14.3 },
    lastTrashVehicle = 0,
    coletaIniciada = false,
    lixeiraCooldowns = {},
    currentLixeiraId = nil,
    pendingEntrega = false,
    pendingEntregaAt = 0,
    entregarRetryAt = nil,
    rgDialogId = nil,
    rgDialogText = nil,
    aguardandoRG = false,
}

local jobs = {"Caminhoneiro", "Lixeiro"}
-- nome do emprego no /rg (minusculo) -> indice em jobs
local JOB_FROM_RG = {
    caminhoneiro = 1,
    lixeiro = 2,
}
local cargoTypes = {"Produtos", "Insumos"}
local VEHICLE_AMOUNTS = {
    [578] = { name = "DFT-30", amount = 900 },
    [440] = { name = "Rumpo",  amount = 400 },
    [414] = { name = "Mule",   amount = 500 },
    [456] = { name = "Yankee", amount = 600 },
    [455] = { name = "Flatbed", amount = 700 },
}
local TRASHMASTER_MODEL = 408

local function getPlayerPos()
    return getCharCoordinates(PLAYER_PED)
end

local function getDistance(x1, y1, z1, x2, y2, z2)
    return getDistanceBetweenCoords3d(x1, y1, z1, x2, y2, z2)
end

local function limparTeclas()
    for _, k in ipairs({0, 1, 2, 3, 4, 5, 6, 14, 15, 16}) do
        setGameKeyState(k, 0)
    end
end

local function formatarDinheiro(valor)
    local s = tostring(math.floor(valor or 0)):reverse():gsub("(%d%d%d)", "%1."):reverse()
    if s:sub(1, 1) == "." then s = s:sub(2) end
    return s
end

local function sendCommand(cmd)
    sampSendChat(cmd)
end

local function pegarDinheiroNaMao()
    local m1 = getPlayerMoney(PLAYER_PED) or 0
    local ok, m2 = pcall(function() return readMemory(0xB7CE50, 4, false) end)
    return math.max(m1, (ok and m2) or 0)
end

-- Propriedade
local function pegarValorFundos()
    for i = 0, 2048 do
        if sampIs3dTextDefined(i) then
            local text = sampGet3dTextInfoById(i)
            if text and text:find("Fundos da empresa") then
                local numeros = text:match("%$(%d[%d%.]*)")
                if numeros then
                    local valor = tonumber((numeros:gsub("%.", "")))
                    if valor and valor > 0 then return valor end
                end
            end
        end
    end
    return 0
end

local function propDepositar(valor)
    valor = tonumber(valor)
    if not valor or valor <= 0 then return end
    sendCommand(string.format("/propriedade depositar %d", valor))
end

local function propSacarTudo()
    local valor = pegarValorFundos()
    if not valor or valor <= 0 then
        state.statusText = "Sem fundos na propriedade"
        return
    end
    sendCommand(string.format("/propriedade sacar %d", valor))
    state.statusText = "Saque: $" .. formatarDinheiro(valor)
end

local function propPedirInsumos(qtd)
    qtd = tonumber(qtd)
    if not qtd or qtd <= 0 then return end
    sendCommand(string.format("/propriedade pedirinsumos %d", qtd))
end

local function propPrecoInsumo(valor)
    valor = tonumber(valor)
    if not valor or valor <= 0 then return end
    sendCommand(string.format("/propriedade precoinsumo %d", valor))
end

-- GGrana
local function executarGGranaTudo()
    if state.ggranaProcessando then return end
    state.ggranaProcessando = true
    lua_thread.create(function()
        local valor = pegarDinheiroNaMao()
        if valor and valor > 0 then
            sendCommand(string.format("/ggrana %d", valor))
        end
        wait(800)
        state.ggranaProcessando = false
    end)
end

-- Auto Droga
local function encontrarPontoDroga()
    for id = 0, 2048 do
        if sampIs3dTextDefined(id) then
            local text, _, x, y, z = sampGet3dTextInfoById(id)
            if text and type(text) == "string" and (text:find("Metanfetamina") or text:find("metanfetamina")) then
                return x, y, z
            end
        end
    end
    return nil
end

local function lerQuantidadeDroga()
    for id = 0, 2048 do
        if sampIs3dTextDefined(id) then
            local text = sampGet3dTextInfoById(id)
            if text and type(text) == "string" then
                if text:find("Quantidade") or text:find("quantidade") or text:find("gram") then
                    local qtd = text:match("(%d+)%s*gram")
                    if qtd then return tonumber(qtd) end
                end
            end
        end
    end
    return 0
end

local function processarCooldownDroga(text)
    if not state.autoDroga[0] or not text then return end
    local min, seg = text:match("[Aa]guarde%s*(%d+)%s*:%s*(%d+)")
    if not min then
        min, seg = text:match("(%d+)%s*:%s*(%d+)%s*para%s*coletar")
    end
    if min and seg then
        local segundos = tonumber(min) * 60 + tonumber(seg)
        if segundos and segundos > 0 and segundos < 600 then
            state.coletando = false
            state.emCooldownDroga = true
            state.tempoCooldownDroga = os.clock() * 1000 + (segundos * 1000) + 3000
            state.waitingDialogFor = nil
        end
    end
end

local function aguardarDialog(timeoutMs)
    local limite = os.clock() * 1000 + (timeoutMs or CONFIG.dialogTimeoutMs)
    state.lastDialogId = nil
    while os.clock() * 1000 < limite do
        if state.lastDialogId ~= nil then return true end
        wait(50)
    end
    return false
end

local function responderDialogDroga(qtd)
    local id = state.lastDialogId
    if id == nil then return false end
    local style = state.lastDialogStyle or 0
    if style == 1 or style == 3 then
        sampSendDialogResponse(id, 1, -1, tostring(qtd))
    else
        sampSendDialogResponse(id, 1, 0, "")
    end
    return true
end

local function coletarDroga()
    if state.coletando or state.emCooldownDroga then return end
    local agora = os.clock() * 1000
    if agora - state.ultimaColeta < CONFIG.intervaloColeta then return end

    local qtd = lerQuantidadeDroga()
    if not qtd or qtd <= 0 then return end

    state.coletando = true
    state.ultimaColeta = agora
    state.waitingDialogFor = "droga"
    state.lastDialogId = nil

    sendCommand("/trafico")

    if state.emCooldownDroga or not aguardarDialog(CONFIG.dialogTimeoutMs) then
        state.coletando = false
        state.waitingDialogFor = nil
        return
    end

    wait(80)
    responderDialogDroga(qtd)
    wait(400)

    if state.lastDialogId ~= nil and state.waitingDialogFor == "droga" then
        local style2 = state.lastDialogStyle or 0
        if style2 == 1 or style2 == 3 then
            sampSendDialogResponse(state.lastDialogId, 1, -1, tostring(qtd))
        else
            sampSendDialogResponse(state.lastDialogId, 1, 0, "")
        end
        wait(300)
    end

    state.waitingDialogFor = nil
    state.coletando = false
end

local function tickAutoDroga()
    if not state.autoDroga[0] then return end

    if state.emCooldownDroga then
        if os.clock() * 1000 >= state.tempoCooldownDroga then
            state.emCooldownDroga = false
            state.coletando = false
            state.ultimaColeta = 0
        end
        return
    end

    if state.coletando then return end

    local x, y, z = encontrarPontoDroga()
    if x then
        state.pontoDrogaX, state.pontoDrogaY, state.pontoDrogaZ = x, y, z
    end
    if not state.pontoDrogaX then return end

    local px, py, pz = getPlayerPos()
    if getDistance(px, py, pz, state.pontoDrogaX, state.pontoDrogaY, state.pontoDrogaZ) > CONFIG.distMaxDroga then
        return
    end

    local qtd = lerQuantidadeDroga()
    if qtd and qtd > 0 then
        lua_thread.create(coletarDroga)
    end
end

-- Auto Roubo
local function textoEhRoubo(texto)
    if not texto then return false end
    local t = texto:lower()
    return t:find("pegargrana") or t:find("bolsa de dinheiro") or t:find("fundo de empresas")
end

local function estaPertoDoCofreRoubo()
    local px, py, pz = getPlayerPos()
    local menorDist = 9999.0
    local encontrou = false
    for id = 0, 2048 do
        if sampIs3dTextDefined(id) then
            local texto, _, x, y, z = sampGet3dTextInfoById(id)
            if textoEhRoubo(texto) then
                local dist = getDistance(px, py, pz, x, y, z)
                if dist < menorDist then
                    menorDist = dist
                    encontrou = true
                end
            end
        end
    end
    return encontrou and menorDist <= CONFIG.distMaxRoubo
end

local function tentarPegarRoubo()
    local agora = getGameTimer()
    if agora - state.ultimoUsoRoubo < CONFIG.cooldownRoubo then return end
    local px, py, pz = getPlayerPos()
    for id = 0, 2048 do
        if sampIs3dTextDefined(id) then
            local texto, _, x, y, z = sampGet3dTextInfoById(id)
            if textoEhRoubo(texto) and getDistance(px, py, pz, x, y, z) <= CONFIG.distMaxRoubo then
                sendCommand("/pegargrana")
                state.ultimoUsoRoubo = agora
                return
            end
        end
    end
end

local function tickAutoRoubo()
    if not state.autoRoubo[0] then return end
    if not estaPertoDoCofreRoubo() then
        state.autoRoubo[0] = false
        return
    end
    tentarPegarRoubo()
end

-- Trabalho BNS
local function findRelevant3dTexts()
    local px, py, pz = getPlayerPos()
    local results = { loadingArea = nil, cargoInfo = nil, storage = {}, farms = {}, lixeira = nil }

    for id = 0, 2048 do
        if sampIs3dTextDefined(id) then
            local text, _, x, y, z = sampGet3dTextInfoById(id)
            if text and text ~= "" then
                local clean = text:gsub("{%x%x%x%x%x%x}", "")
                local distance = getDistance(px, py, pz, x, y, z)
                if distance <= CONFIG.maxDistance then
                    if clean:find("Área de Carregamento") or clean:find("Area de Carregamento")
                        or clean:find("rea de Carregamento") or clean:find("Carregamento")
                        or clean:find("comprarinsumos") or clean:find("comprarprods")
                        or clean:find("carregar o caminh") then
                        results.loadingArea = { id = id, text = clean, x = x, y = y, z = z, dist = distance }
                    end

                    local current, maxc = clean:match("Carga:%s*(%d+)/(%d+)")
                    if not current then current, maxc = clean:match("Carga:%s*(%d+)%s*/%s*(%d+)") end
                    if current and maxc then
                        results.cargoInfo = {
                            id = id, current = tonumber(current), max = tonumber(maxc),
                            x = x, y = y, z = z, dist = distance,
                            tipo = clean:match("Tipo:%s*(%w+)") or "Produtos"
                        }
                    end

                    local storageId = clean:match("Bar%s*%[(%d+)%]")
                        or clean:match("Armazenamento%s*%[(%d+)%]")
                        or clean:match("Comércio%s*%[(%d+)%]")
                        or clean:match("Comercio%s*%[(%d+)%]")
                        or clean:match("%[(%d+)%].-Dono:")
                        or clean:match("%[(%d+)%].-Fundos")
                        or clean:match("%[(%d+)%].-Produtos")
                    if storageId then
                        results.storage[tonumber(storageId)] = { id = id, x = x, y = y, z = z, dist = distance }
                    end

                    local farmId = clean:match("Fazenda%s*#(%d+)") or clean:match("Fazenda%s*(%d+)")
                    if farmId then
                        results.farms[tonumber(farmId)] = { id = id, x = x, y = y, z = z, dist = distance }
                    end

                    if clean:find("[Ll]ixeira") then
                        if not results.lixeira or distance < results.lixeira.dist then
                            local capCur, capMax = clean:match("[Cc]apacidade:%s*(%d+)/(%d+)")
                            if not capCur then capCur, capMax = clean:match("[Cc]apacidade%s*(%d+)/(%d+)") end
                            results.lixeira = {
                                id = id, x = x, y = y, z = z, dist = distance,
                                capacity = tonumber(capCur), capacityMax = tonumber(capMax)
                            }
                        end
                    end
                end
            end
        end
    end
    return results
end

local function getCurrentVehicleInfo()
    if not isCharInAnyCar(PLAYER_PED) then return nil, 900, "Nenhum" end
    local car = storeCarCharIsInNoSave(PLAYER_PED)
    if not car or car == 0 then return nil, 900, "Nenhum" end
    local model = getCarModel(car)
    local info = VEHICLE_AMOUNTS[model]
    if info then return model, info.amount, info.name end
    return model, 900, "Desconhecido"
end

local function isInTrashmaster()
    if not isCharInAnyCar(PLAYER_PED) then return false end
    local car = storeCarCharIsInNoSave(PLAYER_PED)
    if not car or car == 0 then return false end
    return getCarModel(car) == TRASHMASTER_MODEL
end

local function pressKeyY()
    setVirtualKeyDown(VK_Y, true)
    wait(40)
    setVirtualKeyDown(VK_Y, false)
end

local function tryStartService()
    if state.job ~= 1 then return end
    local now = os.clock() * 1000
    if now - state.lastServiceTry < CONFIG.serviceCooldown then return end
    state.lastServiceTry = now
    sendCommand("/truckiniciar")
    state.statusText = "Iniciando servico..."
end

local function doBuy()
    if state.cargoFull then
        state.statusText = "Caminhao cheio"
        return false
    end
    local texts = findRelevant3dTexts()
    if not texts.loadingArea then
        state.statusText = "Area Carregamento nao detectada"
        return false
    end
    if texts.loadingArea.dist > CONFIG.buyDistance then
        state.statusText = string.format("Carregamento a %.1fm", texts.loadingArea.dist)
        return false
    end
    local _, amount = getCurrentVehicleInfo()
    state.lastBuyAmount = amount
    state.currentCargo = amount
    if state.cargoType == 1 then
        sendCommand("/comprarprods " .. amount)
        state.statusText = "Comprando " .. amount .. " produtos"
    else
        sendCommand("/comprarinsumos " .. amount)
        state.statusText = "Comprando " .. amount .. " insumos"
    end
    return true
end

local function doSell()
    local texts = findRelevant3dTexts()
    local targetId = tonumber(ffi.string(state.targetId)) or 1
    if state.cargoType == 1 then
        local storage = texts.storage[targetId]
        if not storage then
            state.statusText = "Comercio [" .. targetId .. "] nao encontrado"
            return false
        end
        if storage.dist > CONFIG.sellDistance then
            state.statusText = string.format("Comercio a %.1fm", storage.dist)
            return false
        end
        sendCommand("/venderprods")
        state.statusText = "Vendendo produtos [" .. targetId .. "]"
    else
        local farm = texts.farms[targetId]
        if not farm then
            state.statusText = "Fazenda #" .. targetId .. " nao encontrada"
            return false
        end
        if farm.dist > CONFIG.sellDistance then
            state.statusText = string.format("Fazenda a %.1fm", farm.dist)
            return false
        end
        sendCommand("/venderinsumos")
        state.statusText = "Vendendo insumos #" .. targetId
    end
    return true
end

local function executeActionTrabalho()
    local now = os.clock() * 1000
    if now - state.lastAction < CONFIG.buyCooldown then return end
    local texts = findRelevant3dTexts()
    local success = false
    if texts.loadingArea and not state.cargoFull then
        success = doBuy()
    end
    if not success and state.cargoFull then
        success = doSell()
    end
    if not success then
        success = doSell()
    end
    if success then state.lastAction = now end
end

local function tryLixeiraInteract()
    if state.job ~= 2 or state.lixeiroFull then return end
    local now = os.clock() * 1000
    if now - state.lastLixeiraAction < CONFIG.lixeiraCooldown then return end

    local texts = findRelevant3dTexts()
    if not texts.lixeira then
        state.currentLixeiraId = nil
        return
    end
    if texts.lixeira.dist > CONFIG.lixeiraDistance then return end

    local lid = texts.lixeira.id
    state.currentLixeiraId = lid
    local cap = texts.lixeira.capacity
    if cap ~= nil and cap < 5 then
        state.statusText = "Lixeira insuficiente (" .. tostring(cap) .. ")"
        return
    end

    local cdUntil = state.lixeiraCooldowns[lid] or 0
    if now < cdUntil then
        state.statusText = "Cooldown lixeira: " .. math.ceil((cdUntil - now) / 1000) .. "s"
        return
    end

    state.lastLixeiraAction = now
    state.statusText = "Ensacando lixo..."
    pressKeyY()
end

local function tryEntregarColeta()
    if state.job ~= 2 or not state.lixeiroFull then return end
    if not state.lixaoPos then
        state.statusText = "Lixao nao configurado"
        return
    end

    local now = os.clock() * 1000
    if state.entregarRetryAt then
        if now < state.entregarRetryAt then return end
        state.entregarRetryAt = nil
    elseif now - state.lastEntregar < CONFIG.entregarCooldown then
        return
    end

    local px, py, pz = getPlayerPos()
    local dist = getDistance(px, py, pz, state.lixaoPos.x, state.lixaoPos.y, state.lixaoPos.z)
    if dist > CONFIG.lixaoDistance then
        state.statusText = string.format("Lixao a %.1fm", dist)
        return
    end

    state.lastEntregar = now
    state.pendingEntrega = true
    state.pendingEntregaAt = now
    sendCommand("/entregarcoleta")
    state.statusText = "Descarregando no lixao..."
end

local function onTrashmasterEnter()
    state.job = 2
    if not state.coletaIniciada then
        state.coletaIniciada = true
        lua_thread.create(function()
            wait(1500)
            sendCommand("/iniciarcoleta")
        end)
    end
    state.statusText = "Lixeiro ativo - coletas: " .. state.coletas .. "/" .. CONFIG.maxColetas
end

local function tickAutoTrabalho()
    if not state.autoTrabalho[0] then return end

    local model = getCurrentVehicleInfo()
    if model and VEHICLE_AMOUNTS[model] then
        if state.lastVehicleModel ~= model then
            state.lastVehicleModel = model
            state.job = 1
        end
    else
        state.lastVehicleModel = 0
    end

    if isInTrashmaster() then
        if state.lastTrashVehicle ~= TRASHMASTER_MODEL then
            state.lastTrashVehicle = TRASHMASTER_MODEL
            onTrashmasterEnter()
        end
    else
        state.lastTrashVehicle = 0
    end

    if state.job == 1 then
        executeActionTrabalho()
    else
        tryLixeiraInteract()
        tryEntregarColeta()
    end
end

-- Eventos
-- Apos /kitvip*: troca pra cada arma e /largararma (exceto faca, desert, m4, sniper)
local function largarArmasExcetoPermitidas()
    for id = 1, 46 do
        if not KEEP_WEAPONS[id] and hasCharGotWeapon(PLAYER_PED, id) then
            setCurrentCharWeapon(PLAYER_PED, id)
            wait(200)
            sendCommand("/largararma")
            wait(4000)
        end
    end
end

local function agendarLargarAposKit()
    lua_thread.create(function()
        wait(CONFIG.delayAposKit)
        largarArmasExcetoPermitidas()
    end)
end

function sampev.onSendCommand(cmd)
    if not cmd or not state.autoLargarArma[0] then return end
    local c = cmd:lower():gsub("^/", "")
    if c:match("^kitvip") then
        agendarLargarAposKit()
    end
end

function sampev.onServerMessage(color, text)
    if not text then return end
    local clean = text:gsub("{%x%x%x%x%x%x}", "")

    processarCooldownDroga(text)

    if state.autoRoubo[0] then
        local msg = text:lower()
        if msg:find("pegou uma bolsa") or (msg:find("do cofre") and msg:find("polícia"))
            or msg:find("pegou dinheiro") or msg:find("aguarde 5 minutos")
            or msg:find("cofre recentemente") or msg:find("para poder pegar mais") then
            state.ultimoUsoRoubo = getGameTimer()
        end
    end

    if not state.autoTrabalho[0] then return end

    if clean:find("Você não está em serviço") or clean:find("nao esta em servico") or clean:find("Use: /truckiniciar") then
        state.inService = false
        if state.job == 1 then tryStartService() end
    end
    if clean:find("entrou em serviço de caminhoneiro") or clean:find("Você entrou em serviço") or clean:find("uniforme aplicado") then
        state.inService = true
        state.statusText = "Em servico"
    end
    if clean:find("Você alugou um") and clean:find("DFT") then
        state.inService = true
    end
    if clean:find("carga máxima") or clean:find("carga maxima") or clean:find("está com a carga máxima") then
        state.cargoFull = true
        state.justBought = true
        local _, amount = getCurrentVehicleInfo()
        state.currentCargo = state.lastBuyAmount > 0 and state.lastBuyAmount or amount
        state.statusText = "Caminhao cheio"
    end
    if clean:find("voce comprou") or clean:find("Voce comprou") or clean:find("produtos foram carregados") or clean:find("insumos foram carregados") then
        state.cargoFull = true
        state.justBought = true
        local _, amount = getCurrentVehicleInfo()
        state.currentCargo = state.lastBuyAmount > 0 and state.lastBuyAmount or amount
    end
    if clean:find("Voce vendeu") or clean:find("voce vendeu") or clean:find("Você vendeu")
        or (clean:find("vendeu") and (clean:find("produtos") or clean:find("insumos"))) then
        local sold = tonumber(clean:match("[Vv]endeu%s+(%d+)")) or 0
        local cargoBefore = state.currentCargo
        if cargoBefore <= 0 then cargoBefore = state.lastBuyAmount end
        if cargoBefore <= 0 then
            local _, amt = getCurrentVehicleInfo()
            cargoBefore = amt
        end
        if sold > 0 then
            state.currentCargo = math.max(0, cargoBefore - sold)
        else
            state.currentCargo = 0
        end
        if sold > 0 and sold < cargoBefore then
            ffi.copy(state.targetId, "0")
            state.statusText = "Troque o ID! Restante: " .. state.currentCargo
            state.cargoFull = true
        else
            state.statusText = "Vendido - reinicie ciclo"
            state.cargoFull = false
            state.justBought = false
            state.currentCargo = 0
            state.lastBuyAmount = 0
        end
    end

    if clean:find("ensacou o lixo") then
        state.coletas = state.coletas + 1
        state.statusText = "Coletas: " .. state.coletas .. "/" .. CONFIG.maxColetas
        if state.coletas >= CONFIG.maxColetas then
            state.lixeiroFull = true
            state.statusText = "CHEIO - va ao lixao"
        end
    end

    if state.job == 2 and (clean:find("esperar") or clean:find("ensacar os lixos dessa lixeira")) then
        local totalSecs = nil
        local mins, secs = clean:match("(%d+)%s*m%s*(%d+)%s*s")
        if mins and secs then
            totalSecs = (tonumber(mins) or 0) * 60 + (tonumber(secs) or 0)
        elseif clean:find("esperar") then
            local onlyMin = clean:match("(%d+)%s*m")
            if onlyMin then totalSecs = (tonumber(onlyMin) or 0) * 60 end
            if not totalSecs then
                local onlySec = clean:match("(%d+)%s*s")
                if onlySec then totalSecs = tonumber(onlySec) end
            end
        end
        if totalSecs and totalSecs > 0 then
            local untilMs = os.clock() * 1000 + (totalSecs * 1000)
            if state.currentLixeiraId then
                state.lixeiraCooldowns[state.currentLixeiraId] = untilMs
            end
            state.statusText = string.format("Cooldown lixeira: %dm %ds", math.floor(totalSecs / 60), totalSecs % 60)
        end
    end

    if state.job == 2 and state.pendingEntrega then
        local now = os.clock() * 1000
        if now - state.pendingEntregaAt > 15000 then
            state.pendingEntrega = false
        else
            local isDeliver =
                (clean:find("entregou") and (clean:find("KG") or clean:find("kg") or clean:find("KGs")))
                or clean:find("Coleta entregue")
                or clean:find("coleta foi entregue")
                or clean:find("lixo foi entregue")
                or (clean:find("descarreg") and clean:find("lixo") and clean:find("sucesso"))
            if isDeliver then
                state.coletas = 0
                state.lixeiroFull = false
                state.pendingEntrega = false
                state.entregarRetryAt = nil
                state.lixeiraCooldowns = {}
                state.statusText = "Lixo entregue"
                if isInTrashmaster() then
                    state.coletaIniciada = true
                    lua_thread.create(function()
                        wait(1500)
                        if isInTrashmaster() then
                            sendCommand("/iniciarcoleta")
                        else
                            state.coletaIniciada = false
                        end
                    end)
                else
                    state.coletaIniciada = false
                end
            elseif clean:find("esperar") or clean:find("aguarde") or clean:find("nao pode")
                or clean:find("não pode") or clean:find("tente novamente") then
                state.entregarRetryAt = now + 2000
                state.pendingEntrega = true
                state.statusText = "Retry entrega em 2s"
            end
        end
    end
end

-- Ao ligar Auto Trabalho: /rg e pega o 1o emprego suportado
local function detectarEmpregoViaRG()
    if state.aguardandoRG then return end
    state.aguardandoRG = true
    state.rgDialogId = nil
    state.rgDialogText = nil
    lua_thread.create(function()
        sendCommand("/rg")
        local limite = os.clock() * 1000 + 5000
        while os.clock() * 1000 < limite and not state.rgDialogText do
            wait(50)
        end
        local blob = state.rgDialogText
        if blob then
            for nome in blob:gmatch("[Ee]mprego:%s*%[([^%]]+)%]") do
                local idx = JOB_FROM_RG[nome:lower():gsub("%s+", "")]
                if idx then
                    state.job = idx
                    state.statusText = "Emprego: " .. jobs[idx]
                    break
                end
            end
            if state.rgDialogId then
                wait(30)
                sampSendDialogResponse(state.rgDialogId, 1, -1, "")
            end
        end
        state.aguardandoRG = false
        state.rgDialogId = nil
        state.rgDialogText = nil
    end)
end

function sampev.onShowDialog(dialogId, style, title, button1, button2, text)
    if state.autoDroga[0] and state.waitingDialogFor == "droga" then
        state.lastDialogId = dialogId
        state.lastDialogStyle = style
        return false
    end

    local titleStr = tostring(title or "")
    local textStr = tostring(text or "")

    if state.aguardandoRG and (titleStr:find("RG de") or textStr:find("[Ee]mprego:")) then
        state.rgDialogId = dialogId
        state.rgDialogText = titleStr .. "\n" .. textStr
        return false
    end

    if not state.autoTrabalho[0] or state.job ~= 2 or state.lixeiroFull then return end
    local low = (titleStr .. " " .. textStr):lower()
    if low:find("escolha uma op") or low:find("ensacar") or low:find("lixeira") then
        lua_thread.create(function()
            wait(50)
            sampSendDialogResponse(dialogId, 1, 4, "")
        end)
        return false
    end
end

-- Painel
local function drawMenu()
    imgui.SetNextWindowSize(imgui.ImVec2(430, 480), imgui.Cond.FirstUseEver)
    imgui.Begin("PlayerOps v1.5", state.menuOpen, imgui.WindowFlags.NoCollapse)

    imgui.TextColored(imgui.ImVec4(0.2, 0.9, 1.0, 1.0), "Status: " .. state.statusText)
    imgui.Separator()

    if imgui.BeginTabBar("##playerops_tabs") then

        -- ABA MODULOS
        if imgui.BeginTabItem("Modulos") then
            imgui.Spacing()
            if imgui.Checkbox("Auto Droga (Metanfetamina)", state.autoDroga) then
                if state.autoDroga[0] then
                    local x, y, z = encontrarPontoDroga()
                    if x then
                        local px, py, pz = getPlayerPos()
                        if getDistance(px, py, pz, x, y, z) <= CONFIG.distMaxDroga then
                            state.pontoDrogaX, state.pontoDrogaY, state.pontoDrogaZ = x, y, z
                            state.ultimaColeta = 0
                            state.emCooldownDroga = false
                            state.coletando = false
                        else
                            state.autoDroga[0] = false
                        end
                    else
                        state.autoDroga[0] = false
                    end
                else
                    state.coletando = false
                    state.emCooldownDroga = false
                end
            end

            if imgui.Checkbox("Auto Roubo Cofre (/pegargrana)", state.autoRoubo) then
                if state.autoRoubo[0] and not estaPertoDoCofreRoubo() then
                    state.autoRoubo[0] = false
                end
            end

            if imgui.Checkbox("Auto Trabalho BNS", state.autoTrabalho) then
                if state.autoTrabalho[0] then
                    detectarEmpregoViaRG()
                end
            end

            if state.autoTrabalho[0] then
                imgui.Spacing()
                imgui.Separator()
                imgui.TextColored(imgui.ImVec4(0.3, 1.0, 0.5, 1.0), "Config Trabalho BNS")
                imgui.Spacing()
                imgui.Text("Trabalho: " .. (jobs[state.job] or "?"))
                if imgui.BeginCombo("##job", jobs[state.job]) then
                    for i, name in ipairs(jobs) do
                        if imgui.Selectable(name, state.job == i) then state.job = i end
                    end
                    imgui.EndCombo()
                end

                if state.job == 1 then
                    imgui.Text("Tipo de Carga:")
                    if imgui.BeginCombo("##cargo", cargoTypes[state.cargoType]) then
                        for i, name in ipairs(cargoTypes) do
                            if imgui.Selectable(name, state.cargoType == i) then state.cargoType = i end
                        end
                        imgui.EndCombo()
                    end
                    imgui.Text(state.cargoType == 1 and "ID do Comercio:" or "ID da Fazenda:")
                    imgui.InputText("##targetId", state.targetId, 32)
                    local _, amount, vehName = getCurrentVehicleInfo()
                    imgui.TextDisabled(string.format("Veiculo: %s | Cap: %d", vehName or "-", amount or 0))
                    imgui.TextDisabled(string.format("Carga atual: %d | Cheio: %s", state.currentCargo, state.cargoFull and "Sim" or "Nao"))
                else
                    imgui.Text(string.format("Coletas: %d / %d", state.coletas, CONFIG.maxColetas))
                    imgui.TextDisabled(string.format("Lixao: %.1f, %.1f, %.1f", state.lixaoPos.x, state.lixaoPos.y, state.lixaoPos.z))
                    if imgui.Button("Salvar posicao do lixao") then
                        local x, y, z = getPlayerPos()
                        state.lixaoPos = { x = x, y = y, z = z }
                        state.statusText = "Lixao salvo"
                    end
                end
            end
            imgui.EndTabItem()
        end

        -- ABA PROPRIEDADE
        if imgui.BeginTabItem("Propriedade") then
            imgui.Spacing()
            local fundos = pegarValorFundos()
            imgui.Text(string.format("Fundos: $%s", formatarDinheiro(fundos)))
            if imgui.Button("Sacar tudo") then
                propSacarTudo()
            end
            imgui.TextDisabled("/propriedade sacar [tudo]")
            imgui.Spacing()
            imgui.Separator()

            imgui.Text("Depositar:")
            if imgui.Button("50k##dep") then propDepositar(50000) end
            imgui.SameLine()
            if imgui.Button("100k##dep") then propDepositar(100000) end
            imgui.SameLine()
            if imgui.Button("150k##dep") then propDepositar(150000) end
            imgui.SameLine()
            if imgui.Button("200k##dep") then propDepositar(200000) end
            imgui.InputText("##propDep", state.propDepositCustom, 32)
            imgui.SameLine()
            if imgui.Button("OK##dep") then
                propDepositar(ffi.string(state.propDepositCustom))
            end
            imgui.Spacing()
            imgui.Separator()

            imgui.Text("Pedir insumos:")
            if imgui.Button("1##ins") then propPedirInsumos(1) end
            imgui.SameLine()
            if imgui.Button("5k##ins") then propPedirInsumos(5000) end
            imgui.SameLine()
            if imgui.Button("10k##ins") then propPedirInsumos(10000) end
            imgui.SameLine()
            if imgui.Button("20k##ins") then propPedirInsumos(20000) end
            imgui.TextDisabled("1 = desativa a compra")
            imgui.Spacing()
            imgui.Separator()

            imgui.Text("Preco insumo:")
            if imgui.Button("10##prc") then propPrecoInsumo(10) end
            imgui.SameLine()
            if imgui.Button("20##prc") then propPrecoInsumo(20) end
            imgui.SameLine()
            if imgui.Button("30##prc") then propPrecoInsumo(30) end
            imgui.SameLine()
            if imgui.Button("40##prc") then propPrecoInsumo(40) end
            imgui.SameLine()
            if imgui.Button("50##prc") then propPrecoInsumo(50) end
            imgui.InputText("##propPreco", state.propPrecoCustom, 32)
            imgui.SameLine()
            if imgui.Button("OK##prc") then
                propPrecoInsumo(ffi.string(state.propPrecoCustom))
            end
            imgui.EndTabItem()
        end

        -- ABA EXTRAS
        if imgui.BeginTabItem("Extras") then
            imgui.Spacing()
            imgui.Text(string.format("Dinheiro na mao: $%s", formatarDinheiro(pegarDinheiroNaMao())))
            if imgui.Button("Guardar tudo (/ggrana)") then
                executarGGranaTudo()
            end
            imgui.TextDisabled("Ou use /gg no chat")
            imgui.Spacing()
            imgui.Separator()
            imgui.Checkbox("Largar armas apos /kitvip", state.autoLargarArma)
            imgui.TextDisabled("Apos kitvip: larga todas as armas")
            imgui.TextDisabled("exceto faca, desert, m4 e sniper")
            imgui.TextDisabled("(4s entre cada /largararma)")
            imgui.EndTabItem()
        end

        imgui.EndTabBar()
    end

    imgui.Spacing()
    imgui.Separator()
    imgui.TextColored(imgui.ImVec4(0.5, 0.5, 0.5, 1.0), "/playerops = painel | /gg = guardar tudo")
    imgui.End()
end

function main()
    -- Aguarda SA-MP ficar disponivel (nao retorna cedo ou o script morre)
    while not isSampAvailable() do
        wait(200)
    end

    sampRegisterChatCommand("gg", function()
        executarGGranaTudo()
    end)

    sampRegisterChatCommand("playerops", function()
        state.menuOpen[0] = not state.menuOpen[0]
    end)

    sampRegisterChatCommand("playeropslixao", function()
        local x, y, z = getPlayerPos()
        state.lixaoPos = { x = x, y = y, z = z }
        state.statusText = "Lixao salvo"
    end)

    imgui.OnFrame(
        function() return state.menuOpen[0] end,
        function() drawMenu() end
    )

    while true do
        wait(CONFIG.checkInterval)
        if isSampAvailable() then
            tickAutoDroga()
            tickAutoRoubo()
            tickAutoTrabalho()
        end
    end
end

function onScriptTerminate(script, quitGame)
    if script == thisScript() then
        limparTeclas()
    end
end
