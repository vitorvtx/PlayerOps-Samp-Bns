--[[
    PlayerOps
    MoonLoader SA-MP
    
    Painel unico (ImGui) para ativar/desativar:
      - Auto Cofre (saca fundos da empresa)
      - GGrana (mostrar dinheiro na mao + guardar tudo)
      - Auto Droga (Metanfetamina /trafico) — sem movimento e sem teclas fisicas
      - Auto Roubo Cofre (/pegargrana)
      - Auto Trabalho BNS (Caminhoneiro + Lixeiro)
    
    SEM mensagens no chat.
    Comandos: /playerops | /gg (guardar tudo) | /playeropslixao
    Versao: 1.3
]]

script_name("PlayerOps")
script_author("Grok")
script_version("1.3")
script_description("PlayerOps - Helpers BNS - painel silencioso")
script_properties('work-in-pause')

require "lib.moonloader"
local sampev = require "lib.samp.events"
local imgui  = require "mimgui"
local encoding = require "encoding"
encoding.default = "CP1252"
local u8 = encoding.UTF8
local ffi = require "ffi"
local vk  = require "vkeys"

ffi.cdef[[
    void keybd_event(unsigned char bVk, unsigned char bScan, unsigned long dwFlags, unsigned long dwExtraInfo);
]]
local KEYEVENTF_KEYUP = 0x0002
local VK_Y     = 0x59

-- ===================== CONFIG =====================
local CONFIG = {
    -- Geral
    checkInterval    = 300,

    -- Auto Cofre
    delayAposSacar   = 2500,
    intervaloCheck   = 500,

    -- Auto Droga
    distMaxDroga     = 5.0,
    intervaloColeta  = 15000,
    dialogTimeoutMs  = 4000,

    -- Auto Roubo Cofre
    cooldownRoubo    = 5 * 60 * 1000,
    distMaxRoubo     = 5.0,

    -- Trabalho BNS
    maxDistance      = 25.0,
    buyDistance      = 14.5,
    sellDistance     = 7.0,
    buyCooldown      = 1200,
    sellCooldown     = 1200,
    serviceCooldown  = 5000,
    lixeiraDistance  = 3.5,
    lixaoDistance    = 10.0,
    maxColetas       = 5,
    lixeiraCooldown  = 800,
    entregarCooldown = 3000,
}

-- ===================== ESTADO =====================
local state = {
    menuOpen = imgui.new.bool(false),

    -- Toggles
    autoCofre    = imgui.new.bool(false),
    autoDroga    = imgui.new.bool(false),
    autoRoubo    = imgui.new.bool(false),
    autoTrabalho = imgui.new.bool(false),

    -- Auto Cofre
    processandoCofre = false,
    ultimoValorCofre = 0,

    -- GGrana (manual / qualquer local)
    ggranaProcessando = false,
    dinheiroMaoCache  = 0,

    -- Auto Droga
    pontoDrogaX, pontoDrogaY, pontoDrogaZ = nil, nil, nil,
    coletando = false,
    emCooldownDroga = false,
    tempoCooldownDroga = 0,
    ultimaColeta = 0,
    -- Dialog SA-MP (evita tecla Enter/F e entrar em veiculo)
    lastDialogId = nil,
    lastDialogStyle = nil,
    lastDialogTitle = nil,
    lastDialogText = nil,
    waitingDialogFor = nil, -- "droga" quando aguardando dialog do /trafico

    -- Auto Roubo
    ultimoUsoRoubo = 0,

    -- Trabalho BNS
    job = 1,                        -- 1 caminhoneiro, 2 lixeiro
    cargoType = 1,                  -- 1 produtos, 2 insumos
    targetId = imgui.new.char[32]("1"),
    lastAction = 0,
    lastCapacity = 0,
    lastMaxCapacity = 0,
    statusText = "Aguardando...",
    inService = false,
    lastServiceTry = 0,
    cargoFull = false,
    justSold = false,
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
}

local jobs = {"Caminhoneiro", "Lixeiro"}
local cargoTypes = {"Produtos", "Insumos"}

local VEHICLE_AMOUNTS = {
    [578] = { name = "DFT-30", amount = 900 },
    [440] = { name = "Rumpo",  amount = 400 },
    [414] = { name = "Mule",   amount = 500 },
    [456] = { name = "Yankee", amount = 600 },
    [455] = { name = "Flatbed", amount = 700 },
}
local TRASHMASTER_MODEL = 408

-- ===================== UTILS =====================
local function getPlayerPos()
    local x, y, z = getCharCoordinates(PLAYER_PED)
    return x, y, z
end

local function getDistance(x1, y1, z1, x2, y2, z2)
    return getDistanceBetweenCoords3d(x1, y1, z1, x2, y2, z2)
end

local function limparTeclas()
    setGameKeyState(0, 0)
    setGameKeyState(1, 0)
    setGameKeyState(2, 0)
    setGameKeyState(3, 0)
    setGameKeyState(4, 0)
    setGameKeyState(5, 0)
    setGameKeyState(6, 0)
    setGameKeyState(14, 0)
    setGameKeyState(15, 0)
    setGameKeyState(16, 0)
end

local function formatarDinheiro(valor)
    local s = tostring(math.floor(valor))
    local formatted = s:reverse():gsub("(%d%d%d)", "%1."):reverse()
    if formatted:sub(1, 1) == "." then
        formatted = formatted:sub(2)
    end
    return formatted
end

local function sendCommand(cmd)
    sampSendChat(cmd)
end

-- ===================== AUTO COFRE =====================
local function pegarValorFundos()
    for i = 0, 2048 do
        if sampIs3dTextDefined(i) then
            local text = sampGet3dTextInfoById(i)
            if text and text:find("Fundos da empresa") then
                local numeros = text:match("%$(%d[%d%.]*)")
                if numeros then
                    local valor = tonumber((numeros:gsub("%.", "")))
                    if valor and valor > 0 then
                        return valor
                    end
                end
            end
        end
    end
    return nil
end

local function pegarDinheiroNaMao()
    local money1 = getPlayerMoney(PLAYER_PED)
    local ok, money2 = pcall(function() return readMemory(0xB7CE50, 4, false) end)
    if not ok then money2 = 0 end
    return math.max(money1 or 0, money2 or 0)
end

-- Auto Cofre: apenas saca fundos da empresa (sem /ggrana)
local function sacarFundos(valor)
    if valor <= 0 then
        state.processandoCofre = false
        return
    end
    if valor == state.ultimoValorCofre then
        state.processandoCofre = false
        return
    end
    state.ultimoValorCofre = valor

    sendCommand(string.format("/propriedade sacar %d", valor))
    wait(CONFIG.delayAposSacar)
    wait(500)

    state.ultimoValorCofre = 0
    state.processandoCofre = false
end

local function tickAutoCofre()
    if not state.autoCofre[0] or state.processandoCofre then return end
    local valor = pegarValorFundos()
    if valor and valor > 0 then
        state.processandoCofre = true
        lua_thread.create(function()
            sacarFundos(valor)
        end)
    end
end

-- ===================== GGRANA (qualquer local) =====================
local function executarGGranaTudo()
    if state.ggranaProcessando then return end
    state.ggranaProcessando = true
    lua_thread.create(function()
        local valor = pegarDinheiroNaMao()
        state.dinheiroMaoCache = valor
        if valor and valor > 0 then
            sendCommand(string.format("/ggrana %d", valor))
        end
        wait(800)
        state.ggranaProcessando = false
        state.dinheiroMaoCache = pegarDinheiroNaMao()
    end)
end

-- ===================== AUTO DROGA =====================
-- Sem nenhum movimento / tecla W. So coleta se voce estiver perto.
local function encontrarPontoDroga()
    for id = 0, 2048 do
        if sampIs3dTextDefined(id) then
            local text, color, x, y, z = sampGet3dTextInfoById(id)
            if text and type(text) == "string" then
                if text:find("Metanfetamina") or text:find("metanfetamina") then
                    return x, y, z
                end
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

-- Aguarda dialog SA-MP sem usar tecla fisica (evita Enter/F e entrar em moto)
local function aguardarDialog(timeoutMs)
    local limite = os.clock() * 1000 + (timeoutMs or CONFIG.dialogTimeoutMs)
    state.lastDialogId = nil
    while os.clock() * 1000 < limite do
        if state.lastDialogId ~= nil then
            return true
        end
        wait(50)
    end
    return false
end

local function responderDialogDroga(qtd)
    local id = state.lastDialogId
    if id == nil then return false end
    local style = state.lastDialogStyle or 0
    -- style 1 = INPUT, 3 = PASSWORD → envia quantidade no campo
    if style == 1 or style == 3 then
        sampSendDialogResponse(id, 1, -1, tostring(qtd))
        return true
    end
    -- LIST / TABLIST / MESSAGE → confirma botao 1 (item 0)
    sampSendDialogResponse(id, 1, 0, "")
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

    -- Nenhuma tecla fisica: so comando + resposta de dialog SA-MP
    sendCommand("/trafico")

    if state.emCooldownDroga then
        state.coletando = false
        state.waitingDialogFor = nil
        return
    end

    if aguardarDialog(CONFIG.dialogTimeoutMs) then
        if state.emCooldownDroga then
            state.coletando = false
            state.waitingDialogFor = nil
            return
        end
        wait(80)
        responderDialogDroga(qtd)
        wait(400)
        -- Se abriu segundo dialog (confirmacao / input de qtd), responde de novo
        if state.lastDialogId ~= nil and state.waitingDialogFor == "droga" then
            local id2 = state.lastDialogId
            local style2 = state.lastDialogStyle or 0
            if style2 == 1 or style2 == 3 then
                sampSendDialogResponse(id2, 1, -1, tostring(qtd))
            else
                sampSendDialogResponse(id2, 1, 0, "")
            end
            wait(300)
        end
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

    if not state.coletando then
        local x, y, z = encontrarPontoDroga()
        if x then
            state.pontoDrogaX, state.pontoDrogaY, state.pontoDrogaZ = x, y, z
        end
        if state.pontoDrogaX then
            local px, py, pz = getPlayerPos()
            local d = getDistance(px, py, pz, state.pontoDrogaX, state.pontoDrogaY, state.pontoDrogaZ)
            -- So coleta se estiver perto; nao anda e nao aperta tecla
            if d <= CONFIG.distMaxDroga then
                local qtd = lerQuantidadeDroga()
                if qtd and qtd > 0 then
                    lua_thread.create(coletarDroga)
                end
            end
        end
    end
end

-- ===================== AUTO ROUBO COFRE =====================
local function estaPertoDoCofreRoubo()
    local px, py, pz = getPlayerPos()
    local menorDist = 9999.0
    local encontrou = false

    for id = 0, 2048 do
        if sampIs3dTextDefined(id) then
            local texto, cor, x, y, z = sampGet3dTextInfoById(id)
            if texto and (
                texto:lower():find("pegargrana") or
                texto:lower():find("bolsa de dinheiro") or
                texto:lower():find("fundo de empresas")
            ) then
                local dist = getDistance(px, py, pz, x, y, z)
                if dist < menorDist then
                    menorDist = dist
                    encontrou = true
                end
            end
        end
    end

    if encontrou and menorDist <= CONFIG.distMaxRoubo then
        return true, menorDist
    end
    return false, menorDist
end

local function tentarPegarRoubo()
    local agora = getGameTimer()
    if agora - state.ultimoUsoRoubo < CONFIG.cooldownRoubo then
        return
    end

    local px, py, pz = getPlayerPos()
    for id = 0, 2048 do
        if sampIs3dTextDefined(id) then
            local texto, cor, x, y, z = sampGet3dTextInfoById(id)
            if texto and (
                texto:lower():find("pegargrana") or
                texto:lower():find("bolsa de dinheiro") or
                texto:lower():find("fundo de empresas")
            ) then
                local dist = getDistance(px, py, pz, x, y, z)
                if dist <= CONFIG.distMaxRoubo then
                    sendCommand("/pegargrana")
                    state.ultimoUsoRoubo = agora
                    return
                end
            end
        end
    end
end

local function tickAutoRoubo()
    if not state.autoRoubo[0] then return end
    local perto = estaPertoDoCofreRoubo()
    if not perto then
        state.autoRoubo[0] = false
        return
    end
    tentarPegarRoubo()
end

-- ===================== AUTO TRABALHO BNS =====================
local function findRelevant3dTexts()
    local px, py, pz = getPlayerPos()
    local results = {
        loadingArea = nil,
        cargoInfo = nil,
        storage = {},
        farms = {},
        lixeira = nil,
    }

    for id = 0, 2048 do
        if sampIs3dTextDefined(id) then
            local text, color, x, y, z = sampGet3dTextInfoById(id)
            if text and text ~= "" then
                local clean = text:gsub("{%x%x%x%x%x%x}", "")
                local distance = getDistance(px, py, pz, x, y, z)

                if distance <= CONFIG.maxDistance then
                    local isLoading = clean:find("Área de Carregamento")
                                   or clean:find("Area de Carregamento")
                                   or clean:find("rea de Carregamento")
                                   or clean:find("Carregamento")
                                   or clean:find("comprarinsumos")
                                   or clean:find("comprarprods")
                                   or clean:find("carregar o caminh")

                    if isLoading then
                        results.loadingArea = {
                            id = id, text = clean, x = x, y = y, z = z, dist = distance
                        }
                    end

                    local current, maxc = clean:match("Carga:%s*(%d+)/(%d+)")
                    if not current then
                        current, maxc = clean:match("Carga:%s*(%d+)%s*/%s*(%d+)")
                    end
                    if current and maxc then
                        results.cargoInfo = {
                            id = id, text = clean,
                            current = tonumber(current), max = tonumber(maxc),
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
                        results.storage[tonumber(storageId)] = {
                            id = id, text = clean, x = x, y = y, z = z, dist = distance
                        }
                    end

                    local farmId = clean:match("Fazenda%s*#(%d+)")
                                or clean:match("Fazenda%s*(%d+)")
                                or clean:match("Fazenda.-#(%d+)")
                                or clean:match("Fazenda.-(%d+)")

                    if farmId then
                        results.farms[tonumber(farmId)] = {
                            id = id, text = clean, x = x, y = y, z = z, dist = distance
                        }
                    end

                    if clean:find("Lixeira") or clean:find("lixeira") then
                        if not results.lixeira or distance < results.lixeira.dist then
                            local capCur, capMax = clean:match("[Cc]apacidade:%s*(%d+)/(%d+)")
                            if not capCur then
                                capCur, capMax = clean:match("[Cc]apacidade%s*(%d+)/(%d+)")
                            end
                            results.lixeira = {
                                id = id, text = clean, x = x, y = y, z = z, dist = distance,
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
    if not isCharInAnyCar(PLAYER_PED) then
        return nil, 900, "Nenhum"
    end
    local car = storeCarCharIsInNoSave(PLAYER_PED)
    if not car or car == 0 then
        return nil, 900, "Nenhum"
    end
    local model = getCarModel(car)
    local info = VEHICLE_AMOUNTS[model]
    if info then
        return model, info.amount, info.name
    end
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

    local model, amount, vehName = getCurrentVehicleInfo()
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
    if success then
        state.lastAction = now
    end
end

local function tryLixeiraInteract()
    if state.job ~= 2 then return end
    if state.lixeiroFull then return end

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
        local left = math.ceil((cdUntil - now) / 1000)
        state.statusText = "Cooldown lixeira: " .. left .. "s"
        return
    end

    state.lastLixeiraAction = now
    state.statusText = "Ensacando lixo..."
    pressKeyY()
end

local function tryEntregarColeta()
    if state.job ~= 2 then return end
    if not state.lixeiroFull then return end
    if not state.lixaoPos then
        state.statusText = "Lixao nao configurado"
        return
    end

    local now = os.clock() * 1000
    local cd = state.entregarRetryAt and 2000 or CONFIG.entregarCooldown
    if state.entregarRetryAt then
        if now < state.entregarRetryAt then return end
        state.entregarRetryAt = nil
        cd = 0
    end
    if now - state.lastEntregar < (cd > 0 and cd or 2000) then return end

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

    -- Auto-ativa ao entrar em veiculo de entrega
    local model, amount, vehName = getCurrentVehicleInfo()
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
    elseif state.job == 2 then
        tryLixeiraInteract()
        tryEntregarColeta()
    end
end

-- ===================== EVENTOS DO SERVIDOR =====================
function sampev.onServerMessage(color, text)
    if not text then return end
    local clean = text:gsub("{%x%x%x%x%x%x}", "")

    -- Auto Cofre
    if state.autoCofre[0] then
        if text:find("Você retirou") and text:find("da propriedade") then
            local valor_retirado = text:match("%$(%d[%d%.]*)")
            if valor_retirado then
                local v = tonumber((valor_retirado:gsub("%.", "")))
                if v then state.ultimoValorCofre = v end
            end
        end
    end

    -- Auto Droga
    processarCooldownDroga(text)

    -- Auto Roubo
    if state.autoRoubo[0] then
        local msg = text:lower()
        if msg:find("pegou uma bolsa") or
           (msg:find("do cofre") and msg:find("polícia")) or
           msg:find("pegou dinheiro") or
           msg:find("aguarde 5 minutos") or
           msg:find("cofre recentemente") or
           msg:find("para poder pegar mais") then
            state.ultimoUsoRoubo = getGameTimer()
        end
    end

    -- Trabalho BNS
    if state.autoTrabalho[0] then
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
        if clean:find("Voce vendeu") or clean:find("voce vendeu") or clean:find("Você vendeu") or (clean:find("vendeu") and (clean:find("produtos") or clean:find("insumos"))) then
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

        -- Lixeiro
        if clean:find("ensacou o lixo") or clean:find("ensacou o lixo que estava") then
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
            end
            if not totalSecs then
                local onlyMin = clean:match("(%d+)%s*m")
                if onlyMin and clean:find("esperar") then
                    totalSecs = (tonumber(onlyMin) or 0) * 60
                end
            end
            if not totalSecs then
                local onlySec = clean:match("(%d+)%s*s")
                if onlySec and clean:find("esperar") then
                    totalSecs = tonumber(onlySec)
                end
            end
            if totalSecs and totalSecs > 0 then
                local untilMs = os.clock() * 1000 + (totalSecs * 1000)
                if state.currentLixeiraId then
                    state.lixeiraCooldowns[state.currentLixeiraId] = untilMs
                end
                state.statusText = string.format("Cooldown lixeira: %dm %ds", math.floor(totalSecs/60), totalSecs%60)
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
                elseif clean:find("esperar") or clean:find("aguarde") or clean:find("nao pode") or clean:find("não pode") or clean:find("tente novamente") then
                    state.entregarRetryAt = now + 2000
                    state.pendingEntrega = true
                    state.statusText = "Retry entrega em 2s"
                end
            end
        end
    end
end

function sampev.onShowDialog(dialogId, style, title, button1, button2, text)
    -- Guarda dialog para Auto Droga (sem tecla fisica)
    if state.autoDroga[0] and state.waitingDialogFor == "droga" then
        state.lastDialogId = dialogId
        state.lastDialogStyle = style
        state.lastDialogTitle = title
        state.lastDialogText = text
        return false -- nao deixa o jogo processar ate respondermos
    end

    if not state.autoTrabalho[0] or state.job ~= 2 or state.lixeiroFull then return end
    local blob = tostring(title or "") .. " " .. tostring(text or "")
    local low = blob:lower()
    if low:find("escolha uma op") or low:find("ensacar") or low:find("lixeira") then
        lua_thread.create(function()
            wait(50)
            sampSendDialogResponse(dialogId, 1, 4, "")
        end)
        return false
    end
end

-- ===================== PAINEL IMGUI =====================
local function drawMenu()
    imgui.SetNextWindowSize(imgui.ImVec2(420, 520), imgui.Cond.FirstUseEver)
    imgui.Begin("PlayerOps", state.menuOpen, imgui.WindowFlags.NoCollapse)

    imgui.TextColored(imgui.ImVec4(0.2, 0.9, 1.0, 1.0), "Status: " .. state.statusText)
    imgui.Separator()

    -- Toggles principais
    imgui.TextColored(imgui.ImVec4(1.0, 0.85, 0.2, 1.0), "Modulos")
    imgui.Spacing()

    if imgui.Checkbox("Auto Cofre (sacar fundos)", state.autoCofre) then
        if not state.autoCofre[0] then
            state.processandoCofre = false
        end
    end
    imgui.SameLine()
    imgui.TextDisabled("(?)")
    if imgui.IsItemHovered() then
        imgui.SetTooltip("Detecta 'Fundos da empresa' e saca com /propriedade sacar")
    end

    -- GGrana separado (qualquer local)
    imgui.Spacing()
    imgui.TextColored(imgui.ImVec4(0.4, 1.0, 0.5, 1.0), "GGrana")
    state.dinheiroMaoCache = pegarDinheiroNaMao()
    imgui.Text(string.format("Dinheiro na mao: $%s", formatarDinheiro(state.dinheiroMaoCache)))
    if imgui.Button("Guardar tudo (/ggrana)") then
        executarGGranaTudo()
    end
    imgui.SameLine()
    imgui.TextDisabled("(?)")
    if imgui.IsItemHovered() then
        imgui.SetTooltip("Le o valor na mao e envia /ggrana [valor]. Funciona em qualquer local.")
    end
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
        if state.autoRoubo[0] then
            local perto = estaPertoDoCofreRoubo()
            if not perto then
                state.autoRoubo[0] = false
            end
        end
    end

    imgui.Checkbox("Auto Trabalho BNS", state.autoTrabalho)

    imgui.Spacing()
    imgui.Separator()

    -- Config Trabalho
    if state.autoTrabalho[0] then
        imgui.TextColored(imgui.ImVec4(0.3, 1.0, 0.5, 1.0), "Config Trabalho BNS")
        imgui.Spacing()

        imgui.Text("Trabalho:")
        if imgui.BeginCombo("##job", jobs[state.job]) then
            for i, name in ipairs(jobs) do
                if imgui.Selectable(name, state.job == i) then
                    state.job = i
                end
            end
            imgui.EndCombo()
        end

        if state.job == 1 then
            imgui.Text("Tipo de Carga:")
            if imgui.BeginCombo("##cargo", cargoTypes[state.cargoType]) then
                for i, name in ipairs(cargoTypes) do
                    if imgui.Selectable(name, state.cargoType == i) then
                        state.cargoType = i
                    end
                end
                imgui.EndCombo()
            end

            if state.cargoType == 1 then
                imgui.Text("ID do Comercio:")
            else
                imgui.Text("ID da Fazenda:")
            end
            imgui.InputText("##targetid", state.targetId, 32)

            local texts = findRelevant3dTexts()
            if texts.loadingArea then
                local col = texts.loadingArea.dist <= CONFIG.buyDistance and imgui.ImVec4(0.2,1,0.2,1) or imgui.ImVec4(1,0.8,0.2,1)
                imgui.TextColored(col, string.format("Carregamento: %.1fm", texts.loadingArea.dist))
            else
                imgui.TextColored(imgui.ImVec4(0.5,0.5,0.5,1), "Carregamento: longe")
            end

            local tid = tonumber(ffi.string(state.targetId)) or 1
            if state.cargoType == 1 then
                local st = texts.storage[tid]
                if st then
                    local col = st.dist <= CONFIG.sellDistance and imgui.ImVec4(0.2,1,0.2,1) or imgui.ImVec4(1,0.8,0.2,1)
                    imgui.TextColored(col, string.format("Comercio [%d]: %.1fm", tid, st.dist))
                else
                    imgui.TextColored(imgui.ImVec4(0.5,0.5,0.5,1), string.format("Comercio [%d]: longe", tid))
                end
            else
                local fm = texts.farms[tid]
                if fm then
                    local col = fm.dist <= CONFIG.sellDistance and imgui.ImVec4(0.2,1,0.2,1) or imgui.ImVec4(1,0.8,0.2,1)
                    imgui.TextColored(col, string.format("Fazenda #%d: %.1fm", tid, fm.dist))
                else
                    imgui.TextColored(imgui.ImVec4(0.5,0.5,0.5,1), string.format("Fazenda #%d: longe", tid))
                end
            end

            local _, amount, vehName = getCurrentVehicleInfo()
            imgui.Text(string.format("Veiculo: %s | Qtd: %d | Carga: %d", vehName, amount, state.currentCargo))
            imgui.Text(string.format("Cheio: %s", state.cargoFull and "SIM" or "NAO"))
        else
            imgui.Text(string.format("Coletas: %d / %d", state.coletas, CONFIG.maxColetas))
            imgui.Text(string.format("Cheio: %s", state.lixeiroFull and "SIM" or "NAO"))
            if state.lixaoPos then
                local px, py, pz = getPlayerPos()
                local d = getDistance(px, py, pz, state.lixaoPos.x, state.lixaoPos.y, state.lixaoPos.z)
                imgui.Text(string.format("Lixao: %.1fm", d))
            end
            local texts = findRelevant3dTexts()
            if texts.lixeira then
                local col = texts.lixeira.dist <= CONFIG.lixeiraDistance and imgui.ImVec4(0.2,1,0.2,1) or imgui.ImVec4(1,0.8,0.2,1)
                imgui.TextColored(col, string.format("Lixeira: %.1fm", texts.lixeira.dist))
            else
                imgui.TextColored(imgui.ImVec4(0.5,0.5,0.5,1), "Lixeira: longe")
            end
            if imgui.Button("Salvar posicao do Lixao", imgui.ImVec2(-1, 28)) then
                local x, y, z = getPlayerPos()
                state.lixaoPos = { x = x, y = y, z = z }
                state.statusText = "Lixao salvo"
            end
        end
    end

    imgui.Spacing()
    imgui.Separator()
    imgui.TextColored(imgui.ImVec4(0.5, 0.5, 0.5, 1.0), "/playerops = painel | /gg = guardar tudo")
    imgui.TextColored(imgui.ImVec4(0.5, 0.5, 0.5, 1.0), "Nenhuma mensagem no chat")

    imgui.End()
end

-- ===================== MAIN =====================
function main()
    while not isSampAvailable() do wait(100) end
    while not isSampfuncsLoaded() do wait(100) end
    wait(300)

    sampRegisterChatCommand("gg", function()
        executarGGranaTudo()
    end)

    sampRegisterChatCommand("playerops", function()
        state.menuOpen[0] = not state.menuOpen[0]
    end)

    -- Comando silencioso para salvar lixao tambem
    sampRegisterChatCommand("playeropslixao", function()
        local x, y, z = getPlayerPos()
        state.lixaoPos = { x = x, y = y, z = z }
        state.statusText = "Lixao salvo"
    end)

    imgui.OnFrame(
        function() return state.menuOpen[0] end,
        function()
            drawMenu()
        end
    )

    while true do
        wait(CONFIG.checkInterval)

        tickAutoCofre()
        tickAutoDroga()
        tickAutoRoubo()
        tickAutoTrabalho()
    end
end

function onScriptTerminate(script, quitGame)
    if script == thisScript() then
        limparTeclas()
    end
end
