--[[
    PlayerOps v1.8 — MoonLoader SA-MP
    Comandos: /playerops | /gg
    Silencioso (sem mensagens no chat).
]]

script_name("PlayerOps")
script_author("Grok")
script_version("1.8")
script_description("PlayerOps - Helpers BNS")
script_properties('work-in-pause')

require "lib.moonloader"
local sampev = require "lib.samp.events"
local imgui  = require "mimgui"
local ffi    = require "ffi"

local VK_Y = 0x59

local KEEP_WEAPONS = {
    [4]  = true, -- faca
    [24] = true, -- desert
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
    distProp         = 2.0,
}

local state = {
    menuOpen = imgui.new.bool(false),
    liberado = false,
    autoDroga = imgui.new.bool(false),
    autoRoubo = imgui.new.bool(false),
    autoTrabalho = imgui.new.bool(false),
    autoLargarArma = imgui.new.bool(false),
    autoCaixinha = imgui.new.bool(false),
    contaVIP = "—",
    ultimoCaixinha = 0,
    ggranaProcessando = false,
    propDepositCustom = imgui.new.char[32](""),
    propPrecoCustom = imgui.new.char[32](""),
    pontoDrogaX = nil, pontoDrogaY = nil, pontoDrogaZ = nil,
    coletando = false,
    emCooldownDroga = false,
    tempoCooldownDroga = 0,
    ultimaColeta = 0,
    lastDialogId = nil,
    lastDialogStyle = nil,
    waitingDialogFor = nil,
    qtdDrogaPendente = nil,
    drogaStep = 0,
    ultimoUsoRoubo = 0,
    job = 1,
    cargoType = 1,
    targetId = imgui.new.char[32]("1"),
    lastAction = 0,
    statusText = "Aguardando...",
    empregoRG = "—",
    inService = false,
    lastServiceTry = 0,
    cargoFull = false,
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
    toasts = {},
}

local function notify(msg)
    if not msg or msg == "" then return end
    table.insert(state.toasts, { text = tostring(msg), untilMs = getGameTimer() + 2000 })
end

local jobs = {"Caminhoneiro", "Lixeiro"}
local JOB_FROM_RG = { caminhoneiro = 1, lixeiro = 2 }
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

local function formatarDinheiro(valor)
    local s = tostring(math.floor(valor or 0)):reverse():gsub("(%d%d%d)", "%1."):reverse()
    if s:sub(1, 1) == "." then s = s:sub(2) end
    return s
end

local function sendCommand(cmd)
    sampSendChat(cmd)
end

local function limparCores(s)
    return (tostring(s or ""):gsub("{%x%x%x%x%x%x}", ""):gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function pegarDinheiroNaMao()
    local m1 = getPlayerMoney(PLAYER_PED) or 0
    local ok, m2 = pcall(function() return readMemory(0xB7CE50, 4, false) end)
    return math.max(m1, (ok and m2) or 0)
end

-- Propriedade
local function pertoDe3dText(teste, maxDist)
    maxDist = maxDist or CONFIG.distProp
    local px, py, pz = getPlayerPos()
    for i = 0, 2048 do
        if sampIs3dTextDefined(i) then
            local text, _, x, y, z = sampGet3dTextInfoById(i)
            if text and type(text) == "string" and x then
                local clean = limparCores(text)
                if teste(clean) and getDistance(px, py, pz, x, y, z) <= maxDist then
                    return true
                end
            end
        end
    end
    return false
end

-- Cofre empresa (foto bolsa / Fundos da empresa)
local function pertoDoCofreEmpresa()
    return pertoDe3dText(function(t)
        local l = t:lower()
        return l:find("fundos da empresa", 1, true)
            or l:find("bolsa de dinheiro", 1, true)
            or l:find("pegargrana", 1, true)
    end)
end

-- Label da propriedade (Dono / Produtos / Preco)
local function pertoDaPropriedade()
    return pertoDe3dText(function(t)
        local l = t:lower()
        return (l:find("dono", 1, true) and l:find("fundos", 1, true))
            or l:find("produtos requerido", 1, true)
            or l:find("preco por produto", 1, true)
            or l:find("preço por produto", 1, true)
    end)
end

local function pegarValorFundos()
    for i = 0, 2048 do
        if sampIs3dTextDefined(i) then
            local text = sampGet3dTextInfoById(i)
            if text and type(text) == "string" then
                local clean = limparCores(text)
                if clean:find("Fundos da empresa") then
                    local numeros = clean:match("%$(%d[%d%.]*)")
                    if numeros then
                        local valor = tonumber((numeros:gsub("%.", "")))
                        if valor and valor > 0 then return valor end
                    end
                end
            end
        end
    end
    return 0
end

local function propDepositar(valor)
    if not pertoDoCofreEmpresa() then
        notify("Chegue a 2m do cofre")
        return false
    end
    valor = tonumber(valor)
    if not valor or valor <= 0 then return false end
    sendCommand(string.format("/propriedade depositar %d", valor))
    return true
end

local function propSacarTudo()
    if not pertoDoCofreEmpresa() then
        notify("Chegue a 2m do cofre")
        return false
    end
    local valor = pegarValorFundos()
    if not valor or valor <= 0 then
        notify("Sem fundos no cofre")
        return false
    end
    sendCommand(string.format("/propriedade sacar %d", valor))
    state.statusText = "Saque: $" .. formatarDinheiro(valor)
    return true
end

local function propPedirInsumos(qtd)
    if not pertoDaPropriedade() then
        notify("Chegue a 2m da propriedade")
        return false
    end
    qtd = tonumber(qtd)
    if not qtd or qtd <= 0 then return false end
    sendCommand(string.format("/propriedade pedirinsumos %d", qtd))
    return true
end

local function propPrecoInsumo(valor)
    if not pertoDaPropriedade() then
        notify("Chegue a 2m da propriedade")
        return false
    end
    valor = tonumber(valor)
    if not valor or valor <= 0 then return false end
    sendCommand(string.format("/propriedade precoinsumo %d", valor))
    return true
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

-- Auto Droga: 1 scan de 3D text (ponto + quantidade)
local function scanDroga3d()
    local px, py, pz = getPlayerPos()
    local bestX, bestY, bestZ, bestDist
    local qtd = 0
    for id = 0, 2048 do
        if sampIs3dTextDefined(id) then
            local text, _, x, y, z = sampGet3dTextInfoById(id)
            if text and type(text) == "string" then
                local clean = limparCores(text)
                local low = clean:lower()
                if low:find("metanfetamina", 1, true) and x then
                    local d = getDistance(px, py, pz, x, y, z)
                    if not bestDist or d < bestDist then
                        bestDist, bestX, bestY, bestZ = d, x, y, z
                    end
                end
                if qtd <= 0 then
                    local n = clean:match("[Qq]uantidade[^%d]*(%d+)")
                        or clean:match("(%d+)%s*[Gg]ram")
                        or clean:match("(%d+)%s*g%A")
                        or clean:match("(%d+)%s*g$")
                    n = tonumber(n)
                    if n and n > 0 then qtd = n end
                end
            end
        end
    end
    return bestX, bestY, bestZ, bestDist, qtd
end

local function encontrarPontoDroga()
    local x, y, z = scanDroga3d()
    return x, y, z
end

local function fecharDialogPendente(id)
    if id == nil then return end
    pcall(function()
        sampSendDialogResponse(id, 0, -1, "")
    end)
end

local function resetColetaDroga()
    local id = state.lastDialogId
    state.waitingDialogFor = nil
    state.coletando = false
    state.lastDialogId = nil
    state.lastDialogStyle = nil
    state.qtdDrogaPendente = nil
    state.drogaStep = 0
    if id ~= nil then fecharDialogPendente(id) end
end

local function processarCooldownDroga(text)
    if not state.autoDroga[0] or not text then return end
    local min, seg = text:match("[Aa]guarde%s*(%d+)%s*:%s*(%d+)")
    if not min then
        min, seg = text:match("(%d+)%s*:%s*(%d+)%s*para%s*coletar")
    end
    if not min then
        local s = text:match("[Aa]guarde%s*(%d+)%s*seg")
        if s then min, seg = 0, s end
    end
    if min and seg then
        local segundos = tonumber(min) * 60 + tonumber(seg)
        if segundos and segundos > 0 and segundos < 600 then
            state.emCooldownDroga = true
            state.tempoCooldownDroga = os.clock() * 1000 + (segundos * 1000) + 3000
            resetColetaDroga()
        end
    end
end

-- /trafico: 1o Enter -> digitar gramas -> 2o Enter (sem tecla fisica)
local function processarDialogDroga(dialogId, style)
    local qtd = tonumber(state.qtdDrogaPendente) or 0
    style = tonumber(style) or 0

    if style == 1 or style == 3 then
        if qtd <= 0 then
            resetColetaDroga()
            return
        end
        sampSendDialogResponse(dialogId, 1, -1, tostring(qtd))
        state.waitingDialogFor = nil
        state.coletando = false
        state.lastDialogId = nil
        state.qtdDrogaPendente = nil
        state.drogaStep = 0
        state.ultimaColeta = os.clock() * 1000
        return
    end

    if state.drogaStep <= 1 then
        state.drogaStep = 2
        state.lastDialogId = dialogId
        sampSendDialogResponse(dialogId, 1, 0, "")
        return
    end

    if qtd > 0 then
        sampSendDialogResponse(dialogId, 1, -1, tostring(qtd))
        state.waitingDialogFor = nil
        state.coletando = false
        state.lastDialogId = nil
        state.qtdDrogaPendente = nil
        state.drogaStep = 0
        state.ultimaColeta = os.clock() * 1000
    else
        resetColetaDroga()
    end
end

local function coletarDroga(qtd)
    if state.coletando or state.emCooldownDroga then return end
    local agora = os.clock() * 1000
    if agora - state.ultimaColeta < CONFIG.intervaloColeta then return end
    qtd = tonumber(qtd)
    if not qtd or qtd <= 0 then return end

    state.coletando = true
    state.waitingDialogFor = "droga"
    state.drogaStep = 1
    state.lastDialogId = nil
    state.lastDialogStyle = nil
    state.qtdDrogaPendente = qtd

    sendCommand("/trafico")

    local limite = agora + (CONFIG.dialogTimeoutMs or 4000)
    while state.coletando and os.clock() * 1000 < limite do
        if state.emCooldownDroga or not state.autoDroga[0] then
            resetColetaDroga()
            return
        end
        wait(30)
    end
    if state.coletando then resetColetaDroga() end
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

    local x, y, z, dist, qtd = scanDroga3d()
    if x then
        state.pontoDrogaX, state.pontoDrogaY, state.pontoDrogaZ = x, y, z
    elseif not state.pontoDrogaX then
        return
    else
        local px, py, pz = getPlayerPos()
        dist = getDistance(px, py, pz, state.pontoDrogaX, state.pontoDrogaY, state.pontoDrogaZ)
    end

    if (dist or 999) > CONFIG.distMaxDroga then return end
    if qtd and qtd > 0 then
        lua_thread.create(function() coletarDroga(qtd) end)
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

local function processarTextoRG(blob)
    if not blob then return end
    blob = limparCores(blob)
    for nome in blob:gmatch("[Ee]mprego:%s*%[([^%]]+)%]") do
        local idx = JOB_FROM_RG[nome:lower():gsub("%s+", "")]
        if idx then
            state.job = idx
            state.empregoRG = jobs[idx]
            state.statusText = "Emprego: " .. jobs[idx]
            break
        end
    end
    local conta = blob:match("[Cc]onta:%s*%[([^%]]+)%]")
    if conta then state.contaVIP = limparCores(conta) end
end

local function contaPodeCaixinha()
    local c = (state.contaVIP or ""):lower()
    return c:find("rubi", 1, true) ~= nil or c:find("diamante", 1, true) ~= nil
end

local function detectarViaRG()
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
        if state.rgDialogText then
            processarTextoRG(state.rgDialogText)
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

function sampev.onSendCommand(cmd)
    if not state.liberado or not cmd or not state.autoLargarArma[0] then return end
    local c = cmd:lower():gsub("^/", "")
    if c:match("^kitvip") then
        notify("Kitvip -> largar armas")
        agendarLargarAposKit()
    end
end

function sampev.onServerMessage(color, text)
    if not text then return end
    local clean = limparCores(text)

    processarCooldownDroga(clean)

    if state.autoRoubo[0] then
        local msg = text:lower()
        if msg:find("pegou uma bolsa") or (msg:find("do cofre") and msg:find("polícia"))
            or msg:find("pegou dinheiro") or msg:find("aguarde 5 minutos")
            or msg:find("cofre recentemente") or msg:find("para poder pegar mais") then
            state.ultimoUsoRoubo = getGameTimer()
        end
    end

    -- Detector de login: "... login no servidor foi ..."
    -- so ASCII (acento de "último" quebra CP1252 vs UTF-8)
    do
        local low = clean:lower()
        if low:find("login no servidor", 1, true) then
            if not state.liberado then
                state.liberado = true
                state.statusText = "Logado"
                notify("PlayerOps liberado")
                detectarViaRG()
            end
        end
    end

    if not state.liberado then return end

    -- Auto /caixinha: linha "PayDay (...)" (ASCII para nao quebrar encoding)
    if state.autoCaixinha[0] and contaPodeCaixinha() then
        local low = clean:lower()
        if low:find("payday (", 1, true) then
            local now = getGameTimer()
            if now - state.ultimoCaixinha > 1500 then
                state.ultimoCaixinha = now
                sendCommand("/caixinha")
                notify("Caixinha")
            end
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
    if clean:find("carga máxima") or clean:find("carga maxima") or clean:find("está com a carga máxima")
        or clean:find("voce comprou") or clean:find("Voce comprou")
        or clean:find("produtos foram carregados") or clean:find("insumos foram carregados") then
        state.cargoFull = true
        local _, amount = getCurrentVehicleInfo()
        state.currentCargo = state.lastBuyAmount > 0 and state.lastBuyAmount or amount
        state.statusText = "Caminhao cheio"
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

function sampev.onShowDialog(dialogId, style, title, button1, button2, text)
    -- /trafico: 1o Enter -> digitar gramas -> 2o Enter (sem tecla fisica)
    if state.waitingDialogFor == "droga" and state.autoDroga[0] then
        state.lastDialogId = dialogId
        state.lastDialogStyle = style
        lua_thread.create(function()
            wait(40)
            if state.waitingDialogFor == "droga" and state.autoDroga[0] then
                processarDialogDroga(dialogId, style)
            end
        end)
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

local function drawOverlay()
    local now = getGameTimer()
    local i = 1
    while i <= #state.toasts do
        if state.toasts[i].untilMs <= now then
            table.remove(state.toasts, i)
        else
            i = i + 1
        end
    end
    if #state.toasts == 0 then return end

    local flags = imgui.WindowFlags.NoTitleBar
        + imgui.WindowFlags.NoResize
        + imgui.WindowFlags.NoMove
        + imgui.WindowFlags.NoScrollbar
        + imgui.WindowFlags.NoInputs
        + imgui.WindowFlags.AlwaysAutoResize

    local io = imgui.GetIO()
    local y = 80.0
    for idx = #state.toasts, 1, -1 do
        local t = state.toasts[idx]
        local left = t.untilMs - now
        local alpha = left < 350 and (left / 350) or 1.0
        imgui.SetNextWindowPos(imgui.ImVec2(io.DisplaySize.x - 12, y), imgui.Cond.Always, imgui.ImVec2(1, 0))
        imgui.SetNextWindowBgAlpha(0.82 * alpha)
        imgui.Begin("##po_toast" .. idx, nil, flags)
        imgui.TextColored(imgui.ImVec4(0.80, 0.60, 1.0, alpha), t.text)
        y = y + imgui.GetWindowSize().y + 6
        imgui.End()
    end
end

-- Painel (tema roxo escuro)
local PURPLE = {
    { imgui.Col.TitleBg,          0.10, 0.04, 0.16, 1.00 },
    { imgui.Col.TitleBgActive,    0.18, 0.07, 0.28, 1.00 },
    { imgui.Col.TitleBgCollapsed, 0.08, 0.03, 0.12, 1.00 },
    { imgui.Col.WindowBg,         0.05, 0.02, 0.08, 0.97 },
    { imgui.Col.ChildBg,          0.05, 0.02, 0.08, 0.00 },
    { imgui.Col.Border,           0.28, 0.12, 0.42, 0.70 },
    { imgui.Col.FrameBg,          0.10, 0.05, 0.16, 1.00 },
    { imgui.Col.FrameBgHovered,   0.16, 0.08, 0.26, 1.00 },
    { imgui.Col.FrameBgActive,    0.22, 0.10, 0.34, 1.00 },
    { imgui.Col.CheckMark,        0.55, 0.30, 0.85, 1.00 },
    { imgui.Col.Button,           0.22, 0.10, 0.36, 1.00 },
    { imgui.Col.ButtonHovered,    0.32, 0.14, 0.48, 1.00 },
    { imgui.Col.ButtonActive,     0.40, 0.18, 0.58, 1.00 },
    { imgui.Col.Header,           0.22, 0.10, 0.36, 0.85 },
    { imgui.Col.HeaderHovered,    0.32, 0.14, 0.48, 0.95 },
    { imgui.Col.HeaderActive,     0.40, 0.18, 0.58, 1.00 },
    { imgui.Col.Separator,        0.28, 0.12, 0.40, 0.55 },
    { imgui.Col.Tab,              0.12, 0.05, 0.20, 1.00 },
    { imgui.Col.TabHovered,       0.30, 0.14, 0.46, 1.00 },
    { imgui.Col.TabActive,        0.24, 0.10, 0.38, 1.00 },
    { imgui.Col.TabUnfocused,     0.08, 0.04, 0.14, 1.00 },
    { imgui.Col.TabUnfocusedActive, 0.16, 0.07, 0.26, 1.00 },
    { imgui.Col.ScrollbarBg,      0.05, 0.02, 0.08, 0.50 },
    { imgui.Col.ScrollbarGrab,    0.22, 0.10, 0.36, 0.80 },
    { imgui.Col.ScrollbarGrabHovered, 0.32, 0.14, 0.48, 0.90 },
    { imgui.Col.ScrollbarGrabActive,  0.40, 0.18, 0.58, 1.00 },
}

local function drawMenu()
    for _, c in ipairs(PURPLE) do
        imgui.PushStyleColor(c[1], imgui.ImVec4(c[2], c[3], c[4], c[5]))
    end

    imgui.SetNextWindowSize(imgui.ImVec2(430, 480), imgui.Cond.Always)
    imgui.Begin("PlayerOps v1.8", state.menuOpen, imgui.WindowFlags.NoCollapse + imgui.WindowFlags.NoResize)

    if not state.liberado then
        imgui.TextColored(imgui.ImVec4(0.90, 0.35, 0.35, 1.0), "Aguardando login no servidor...")
        imgui.TextDisabled("Libera ao aparecer no chat:")
        imgui.TextDisabled("\"... login no servidor foi ...\"")
        imgui.TextDisabled("Se ja estiver logado, reconecte 1x.")
        imgui.End()
        imgui.PopStyleColor(#PURPLE)
        return
    end

    imgui.TextColored(imgui.ImVec4(0.55, 0.35, 0.80, 1.0), "Status: " .. state.statusText)
    imgui.Separator()

    if imgui.BeginTabBar("##playerops_tabs") then

        -- ABA MODULOS
        if imgui.BeginTabItem("Modulos") then
            imgui.Spacing()
            if imgui.Checkbox("Pegar Droga", state.autoDroga) then
                if state.autoDroga[0] then
                    local x, y, z = encontrarPontoDroga()
                    if x then
                        local px, py, pz = getPlayerPos()
                        if getDistance(px, py, pz, x, y, z) <= CONFIG.distMaxDroga then
                            state.pontoDrogaX, state.pontoDrogaY, state.pontoDrogaZ = x, y, z
                            state.ultimaColeta = 0
                            state.emCooldownDroga = false
                            state.coletando = false
                            notify("Pegar Droga ON")
                        else
                            state.autoDroga[0] = false
                            notify("Pegar Droga: longe do ponto")
                        end
                    else
                        state.autoDroga[0] = false
                        notify("Pegar Droga: ponto nao encontrado")
                    end
                else
                    state.emCooldownDroga = false
                    resetColetaDroga()
                    notify("Pegar Droga OFF")
                end
            end
            imgui.TextDisabled("Coleta metanfetamina perto do ponto")

            imgui.Spacing()
            if imgui.Checkbox("Assistente de roubo", state.autoRoubo) then
                if state.autoRoubo[0] then
                    if not estaPertoDoCofreRoubo() then
                        state.autoRoubo[0] = false
                        notify("Roubo: longe das bolsas")
                    else
                        notify("Assist. Roubo ON")
                    end
                else
                    notify("Assist. Roubo OFF")
                end
            end
            imgui.TextDisabled("Usa /pegargrana perto das bolsas")
            imgui.EndTabItem()
        end

        -- ABA TRABALHO MANAGER
        if imgui.BeginTabItem("Trabalho Manager") then
            imgui.Spacing()
            if imgui.Checkbox("Ativar Trabalho Manager", state.autoTrabalho) then
                if state.autoTrabalho[0] then
                    detectarViaRG()
                    notify("Trabalho Manager ON")
                else
                    notify("Trabalho Manager OFF")
                end
            end
            imgui.TextDisabled("Detecta emprego pelo /rg ao ativar")

            if state.autoTrabalho[0] then
                imgui.Spacing()
                imgui.Separator()
                imgui.TextColored(imgui.ImVec4(0.55, 0.35, 0.80, 1.0),
                    "Emprego atual: " .. (state.empregoRG or "—"))
                imgui.TextDisabled("(lido do /rg — emprego suportado pelo mod)")
                imgui.Spacing()
                imgui.Text("Trabalho ativo: " .. (jobs[state.job] or "?"))
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
                        notify("Lixao salvo")
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
            local noCofre = pertoDoCofreEmpresa()
            local naProp = pertoDaPropriedade()
            imgui.TextDisabled(noCofre and "Cofre: perto" or "Cofre: longe (2m)")
            imgui.TextDisabled(naProp and "Propriedade: perto" or "Propriedade: longe (2m)")
            imgui.Spacing()

            if imgui.Button("Sacar tudo") then
                if propSacarTudo() then notify("Saque propriedade") end
            end
            imgui.TextDisabled("Sacar/depositar: 2m do cofre")
            imgui.Spacing()
            imgui.Separator()

            imgui.Text("Depositar:")
            if imgui.Button("50k##dep") then if propDepositar(50000) then notify("Depositar 50k") end end
            imgui.SameLine()
            if imgui.Button("100k##dep") then if propDepositar(100000) then notify("Depositar 100k") end end
            imgui.SameLine()
            if imgui.Button("150k##dep") then if propDepositar(150000) then notify("Depositar 150k") end end
            imgui.SameLine()
            if imgui.Button("200k##dep") then if propDepositar(200000) then notify("Depositar 200k") end end
            imgui.InputText("##propDep", state.propDepositCustom, 32)
            imgui.SameLine()
            if imgui.Button("OK##dep") then
                local v = ffi.string(state.propDepositCustom)
                if propDepositar(v) then notify("Depositar " .. tostring(v)) end
            end
            imgui.Spacing()
            imgui.Separator()

            imgui.Text("Pedir insumos:")
            if imgui.Button("1##ins") then if propPedirInsumos(1) then notify("Insumos: 1") end end
            imgui.SameLine()
            if imgui.Button("5k##ins") then if propPedirInsumos(5000) then notify("Insumos: 5k") end end
            imgui.SameLine()
            if imgui.Button("10k##ins") then if propPedirInsumos(10000) then notify("Insumos: 10k") end end
            imgui.SameLine()
            if imgui.Button("20k##ins") then if propPedirInsumos(20000) then notify("Insumos: 20k") end end
            imgui.TextDisabled("Insumos/preco: 2m da propriedade")
            imgui.Spacing()
            imgui.Separator()

            imgui.Text("Preco insumo:")
            if imgui.Button("10##prc") then if propPrecoInsumo(10) then notify("Preco: 10") end end
            imgui.SameLine()
            if imgui.Button("20##prc") then if propPrecoInsumo(20) then notify("Preco: 20") end end
            imgui.SameLine()
            if imgui.Button("30##prc") then if propPrecoInsumo(30) then notify("Preco: 30") end end
            imgui.SameLine()
            if imgui.Button("40##prc") then if propPrecoInsumo(40) then notify("Preco: 40") end end
            imgui.SameLine()
            if imgui.Button("50##prc") then if propPrecoInsumo(50) then notify("Preco: 50") end end
            imgui.InputText("##propPreco", state.propPrecoCustom, 32)
            imgui.SameLine()
            if imgui.Button("OK##prc") then
                local v = ffi.string(state.propPrecoCustom)
                if propPrecoInsumo(v) then notify("Preco: " .. tostring(v)) end
            end
            imgui.EndTabItem()
        end

        -- ABA EXTRAS
        if imgui.BeginTabItem("Extras") then
            imgui.Spacing()
            imgui.Text(string.format("Dinheiro na mao: $%s", formatarDinheiro(pegarDinheiroNaMao())))
            if imgui.Button("Guardar tudo (/ggrana)") then
                executarGGranaTudo()
                notify("GGrana")
            end
            imgui.TextDisabled("Ou use /gg no chat")
            imgui.Spacing()
            imgui.Separator()
            if imgui.Checkbox("Largar armas apos /kitvip", state.autoLargarArma) then
                notify(state.autoLargarArma[0] and "Largar armas ON" or "Largar armas OFF")
            end
            imgui.TextDisabled("Apos kitvip: larga todas as armas")
            imgui.TextDisabled("exceto faca, desert, m4 e sniper")
            imgui.TextDisabled("(4s entre cada /largararma)")
            imgui.Spacing()
            imgui.Separator()
            if imgui.Checkbox("Auto /caixinha no PayDay", state.autoCaixinha) then
                if state.autoCaixinha[0] then
                    if not contaPodeCaixinha() then detectarViaRG() end
                    notify("Auto caixinha ON")
                else
                    notify("Auto caixinha OFF")
                end
            end
            imgui.TextDisabled("Conta: " .. (state.contaVIP or "—"))
            imgui.TextDisabled("So Rubi/Diamante | 1x por cada PayDay")
            imgui.EndTabItem()
        end

        imgui.EndTabBar()
    end

    imgui.Spacing()
    imgui.Separator()
    imgui.TextColored(imgui.ImVec4(0.55, 0.45, 0.65, 1.0), "/playerops = painel | /gg = guardar tudo")
    imgui.End()
    imgui.PopStyleColor(#PURPLE)
end

function main()
    while not isSampAvailable() do
        wait(200)
    end

    sampRegisterChatCommand("gg", function()
        if not state.liberado then return end
        executarGGranaTudo()
        notify("GGrana")
    end)

    sampRegisterChatCommand("playerops", function()
        state.menuOpen[0] = not state.menuOpen[0]
    end)

    imgui.OnFrame(
        function() return state.menuOpen[0] end,
        function() drawMenu() end
    )
    imgui.OnFrame(
        function() return #state.toasts > 0 end,
        function() drawOverlay() end
    )

    while true do
        wait(CONFIG.checkInterval)
        if not isSampAvailable() then
            if state.liberado then
                state.liberado = false
                state.autoDroga[0] = false
                state.autoRoubo[0] = false
                state.autoTrabalho[0] = false
                state.statusText = "Aguardando login..."
            end
        elseif state.liberado then
            tickAutoDroga()
            tickAutoRoubo()
            tickAutoTrabalho()
        end
    end
end

function onScriptTerminate(script, quitGame)
    if script == thisScript() then
        for _, k in ipairs({0, 1, 2, 3, 4, 5, 6, 14, 15, 16}) do
            setGameKeyState(k, 0)
        end
    end
end
