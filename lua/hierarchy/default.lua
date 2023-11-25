local utils = require('utils')
local vim = vim

local M = {}

local typeId = {
    treesitter = -1,
    custom = 0,
    languageRoot = 1,
    text = 2,
}
M.typeId = typeId

local nodesInfo = {}
M.nodesInfo = nodesInfo
function nodesInfo.childrenIter(node)
    local children = node.hierarchy.children
    local count = #children
    local i = 0
    return function() if i < count then
        i = i + 1
        return children[i]
    end end
end
function nodesInfo.id(node)
    if node.id == nil then M.nodeSetId(node) end
    return node.id
end
function nodesInfo.range(node) return utils.updateTable({}, node.info.range) end
function nodesInfo.parentPart(node) return node.info.isParentPart == true end
function nodesInfo.parent(node) return node.hierarchy.parent end
function nodesInfo.prev(node) return node.hierarchy.prev end
function nodesInfo.next(node) return node.hierarchy.next end

--[[

id, -- autogenerated
orig,
type,
info = { range, isParentPart },
hierarchy = { prev, next, parent, children, langTree },
static = { properties, idGen, source }

]]

--[[
type = [typeId, info...]
]]

local IdGenerator = {}
IdGenerator.__index = IdGenerator
setmetatable(IdGenerator, IdGenerator)
function IdGenerator:get()
    self[1] = self[1] + 1
    return self[1]
end
function M.createIdGenerator() return setmetatable({ 0 }, IdGenerator) end

function M.nodeSetId(node)
    node.id = node.static.idGenerator:get()
    return node
end

function M.fixChildren(parentNode)
    local children = parentNode.hierarchy.children
    for i, child in pairs(children) do
        local h = child.hierarchy
        h.parent = parentNode
        h.prev   = children[i-1]
        h.next   = children[i+1]
    end
end

function M.nodeContext(node)
    return { siblings = node.hierarchy.children, static = node.static, langTree = node.hierarchy.langTree }
end

function M.treesType(node, langTree)
    return { typeId.treeSitter, lang = langTree:lang(), name = node:type() }
end

function M.treesNodeRange(treesNode)
    return { utils.fixedRange(treesNode:range()) }
end

function M.childrenFromNode(node)
    local children = {}
    node.hierarchy.children = children

    local context = M.nodeContext(node)
    local o = node.orig
    for child in o:iter_children() do M.parseChild(context, child) end
    M.fixChildren(node)

    return children
end

function M.lazyChildren(node)
    return { __index = function(_, key) if key == 'children' then return M.childrenFromNode(node) end end }
end

function M.createNode(treesNode, langTree, static)
    local node = {
        type = M.treesType(treesNode, langTree),
        info = { range = M.treesNodeRange(treesNode), isParentPart = not treesNode:named() },
        orig = treesNode,
        static = static
    }

    local hierarchy = { langTree = langTree }
    setmetatable(hierarchy, M.lazyChildren(node))
    node.hierarchy = hierarchy

    return node
end

function M.parseSplitNode(treesNode, nodeType, params, context)
    local startNode = {
        type = nodeType,
        info = { isParentPart = not treesNode:named() },
        hierarchy = { langTree = context.langTree, children = {} },
        orig = treesNode,
        static = context.static
    }
    local newContext = { siblings = {}, langTree = context.langTree, static = context.static }

    for child in treesNode:iter_children() do
        M.parseChild(newContext, child)
    end

    if #newContext.siblings == 0 then
        startNode.info.range = M.treesNodeRange(treesNode)
        table.insert(context.siblings, startNode)
    end

    local children = newContext.siblings
    local childI = #children+1
    for i=1, #children do
        if params:splitAt(children[i]) then
            childI = i
            break
        else
            table.insert(startNode.hierarchy.children, children[i])
        end
    end

    local c = startNode.hierarchy.children
    if #c ~= 0 then
        local fr = c[1].info.range
        local lr = c[#c].info.range
        startNode.info.range = { fr[1], fr[2], lr[3], lr[4] }
        M.fixChildren(startNode)
        table.insert(context.siblings, startNode)
    end

    for i=childI, #children do
        table.insert(context.siblings, children[i])
    end
end

function M.parseTextNode(treeNode, nodeType, textProperties, context)
    local siblings = context.siblings
    local static   = context.static
    local langTree = context.langTree

    local nodeRange = { utils.fixedRange(treeNode:range()) }

    local boundaryLinesParent = false
    local isText = function(_nodeType, _context) return false end
    if type(textProperties) == 'table' then
        boundaryLinesParent = textProperties.boundaryLinesParent == true or boundaryLinesParent
        isText = textProperties.isText or isText
    end

    local text = vim.treesitter.get_node_text(treeNode, static.source)
    local lines = vim.split(text, "\n") -- pray to all gods that treesitter thinks the same of lines
    utils.assert2(#lines == nodeRange[3] - nodeRange[1] + 1, function() return
        "calculated line count = "..#lines.." for node of type `"..vim.inspect(nodeType)
        .."` must be consistent with treesitter range (" .. nodeRange[1]..', '..nodeRange[2]..', '
        ..nodeRange[3]..', '..nodeRange[4]..') line count = '.. (nodeRange[3] - nodeRange[1] + 1)
    end)

    local children = {}
    local node = {
        type = nodeType,
        info = { range = nodeRange, isParentPart = not treeNode:named() },
        orig = treeNode,
        hierarchy = { children = children, langTree = langTree },
        static = static,
    }

    local function textToNodes(startL, startC, endL, endC)
        local origRange = { startL, startC, endL, endC }
        startL = startL - nodeRange[1]
        endL = endL - nodeRange[1]
        if startL == 0 then
            startC = startC - nodeRange[2]
            if endL == startC then endC = endC - nodeRange[2] end
        end

        local curLines = {}
        for i=startL,endL do
            table.insert(curLines, lines[i+1])
        end
        utils.assert2(#curLines ~= 0, function() return 'incorrect range '..vim.inspect(origRange)..' for text node '..nodeType..' at '..vim.inspect(nodeRange) end)
        curLines[#curLines] = curLines[#curLines]:sub(1, endC+1)
        curLines[1] = curLines[1]:sub(startC+1)

        for i, line in ipairs(curLines) do
            local first = line:find('%S')
            local last  = line:reverse():find('%S') -- findlast
            if first ~= nil and last ~= nil then
                last = #line - last + 1
                table.insert(children, {
                    type = { typeId.text },
                    info = {
                        range = {
                            origRange[1] + i-1,
                            origRange[2] + first-1,
                            origRange[1] + i-1,
                            origRange[2] + last-1,
                        },
                        isParentPart = false
                    },
                    hierarchy = { langTree = langTree, children = {} },
                    static = static
                })
            end
        end
    end

    local prevLine = nodeRange[1]
    local prevCol  = nodeRange[2]

    local context = M.nodeContext(node)
    for child in treeNode:iter_children() do
        if not isText(child, context) then
            local childSL, childSC, childEL, childEC = utils.fixedRange(child:range())
            textToNodes(prevLine, prevCol, childSL, childSC-1)
            M.parseChild(context, child)
            local i = children[#children].info
            prevLine = childEL
            prevCol = childEC + 1
        end
    end
    textToNodes(prevLine, prevCol, nodeRange[3], nodeRange[4])

    if boundaryLinesParent and #children ~= 0 then
        children[1].info.isParentPart = true
        children[#children].info.isParentPart = true
    end

    M.fixChildren(node)
    table.insert(siblings, node)
    return
end

local function findSubtreeForNode(tree, nodeRange)
    -- How do I check if LanguageTree is responsible for this range and get correct root node?
    for _, childTree in pairs(tree:children()) do
        local ranges = childTree:included_regions()
        for rangeIndex, ranges2 in pairs(ranges) do
            for _, range in pairs(ranges2) do -- ??? why is this a table of arrays of ranges
                if utils.isRangeInside(nodeRange, { range[1], range[2], range[4], range[5] }) then
                    return childTree, rangeIndex
                end
            end
        end
    end
end

function M.parseChild(context, treesNode)
    if treesNode == nil then return end

    local siblings = context.siblings
    local static   = context.static
    local langTree = context.langTree
    local properties = static.properties

    local nodeLangTree, rootIndex = findSubtreeForNode(langTree, { treesNode:range() })
    if nodeLangTree ~= nil then -- TODO: check if 2 nodes use same lang tree (should be impossible...)
        local root = nodeLangTree:parse()[rootIndex]:root()
        local parent = {
            type = { typeId.languageRoot, fromTree = context.langTree, toTree = nodeLangTree },
            info = { range = M.treesNodeRange(treesNode), isParentPart = false },
            hierarchy = { children = {}, langTree = nodeLangTree },
            static = static
        }
        M.parseChild(M.nodeContext(parent), root)
        M.fixChildren(parent)
        table.insert(siblings, parent)
        return
    end

    if properties:parseNode(context, treesNode) then return end

    table.insert(siblings, M.createNode(treesNode, langTree, static))
end

M.createRoot = function(source, langTree, properties)
    local root = langTree:parse()[1]:root()
    local idGenerator = M.createIdGenerator()
    local parent = {
        type = { typeId.languageRoot, toTree = langTree },
        info = { isParentPart = false, range = M.treesNodeRange(root) },
        hierarchy = { langTree = langTree, children = {} },
        static = { properties = properties, idGenerator = idGenerator, source = source },
    }
    M.parseChild(M.nodeContext(parent), root)
    M.fixChildren(parent)
    return parent
end

return M
