module Yi.Keymap.Vim2.VisualMap
  ( defVisualMap
  ) where

import Control.Applicative
import Control.Monad
import Control.Lens hiding ((-~), op)

import Data.Char (ord)
import Data.List (group)
import Data.Maybe (fromJust)
import Data.String.Utils (strip)

import Yi.Buffer hiding (Insert)
import Yi.Editor
import Yi.Keymap.Vim2.Common
import Yi.Keymap.Vim2.Operator
import Yi.Keymap.Vim2.StateUtils
import Yi.Keymap.Vim2.StyledRegion
import Yi.Keymap.Vim2.Utils
import Yi.MiniBuffer
import Yi.Utils
import Yi.Monad

defVisualMap :: [VimOperator] -> [VimBinding]
defVisualMap operators =
    [escBinding, motionBinding, changeVisualStyleBinding, setMarkBinding]
    ++ [chooseRegisterBinding]
    ++ operatorBindings operators ++ digitBindings ++ [replaceBinding, switchEdgeBinding]
    ++ [insertBinding, exBinding, shiftDBinding, gotoFileBinding]

escAction :: EditorM RepeatToken
escAction = do
    resetCountE
    clrStatus
    withBuffer0 $ do
        setVisibleSelection False
        assign regionStyleA Inclusive
    switchModeE Normal
    return Drop

escBinding :: VimBinding
escBinding = VimBindingE f
    where f evs (VimState { vsMode = (Visual _) }) = escAction <$
              matchFromBool (evs `elem` ["<Esc>", "<C-c>"])
          f _ _ = NoMatch

exBinding :: VimBinding
exBinding = VimBindingE f
    where f ":" (VimState { vsMode = (Visual _) }) = WholeMatch $ do
              void $ spawnMinibufferE ":'<,'>" id
              switchModeE Ex
              return Finish
          f _ _ = NoMatch

digitBindings :: [VimBinding]
digitBindings = zeroBinding : fmap mkDigitBinding ['1' .. '9']

zeroBinding :: VimBinding
zeroBinding = VimBindingE f
    where f "0" (VimState { vsMode = (Visual _) }) = WholeMatch $ do
              currentState <- getDynamic
              case vsCount currentState of
                  Just c -> do
                      setDynamic $ currentState { vsCount = Just (10 * c) }
                      return Continue
                  Nothing -> do
                      withBuffer0 moveToSol
                      setDynamic $ resetCount currentState
                      return Continue
          f _ _ = NoMatch

setMarkBinding :: VimBinding
setMarkBinding = VimBindingE f
    where f "m" (VimState { vsMode = (Visual _) }) = PartialMatch
          f ('m':c:[]) (VimState { vsMode = (Visual _) }) = WholeMatch $ do
              withBuffer0 $ setNamedMarkHereB [c]
              return Continue
          f _ _ = NoMatch

changeVisualStyleBinding :: VimBinding
changeVisualStyleBinding = VimBindingE f
    where f evs (VimState { vsMode = (Visual _) })
            | evs `elem` ["v", "V", "<C-v>"]
            = WholeMatch $ do
                  currentMode <- fmap vsMode getDynamic
                  let newStyle = case evs of
                         "v" -> Inclusive
                         "V" -> LineWise
                         "<C-v>" -> Block
                         _ -> error "Just silencing false positive warning."
                      newMode = Visual newStyle
                  if newMode == currentMode
                  then escAction
                  else do
                      modifyStateE $ \s -> s { vsMode = newMode }
                      withBuffer0 $ do
                          assign regionStyleA newStyle
                          assign rectangleSelectionA $ Block == newStyle
                          setVisibleSelection True
                      return Finish
          f _ _ = NoMatch

mkDigitBinding :: Char -> VimBinding
mkDigitBinding c = VimBindingE f
    where f [c'] (VimState { vsMode = (Visual _) }) | c == c'
            = WholeMatch $ do
                  modifyStateE mutate
                  return Continue
          f _ _ = NoMatch
          mutate vs@(VimState {vsCount = Nothing}) = vs { vsCount = Just d }
          mutate vs@(VimState {vsCount = Just count}) = vs { vsCount = Just $ count * 10 + d }
          d = ord c - ord '0'

motionBinding :: VimBinding
motionBinding = mkMotionBinding Continue $
    \m -> case m of
        Visual _ -> True
        _ -> False

regionOfSelectionB :: BufferM Region
regionOfSelectionB = savingPointB $ do
    start <- getSelectionMarkPointB
    stop <- pointB
    return $! mkRegion start stop

operatorBindings :: [VimOperator] -> [VimBinding]
operatorBindings operators = fmap mkOperatorBinding $ operators ++ visualOperators
    where visualOperators = fmap synonymOp
                                  [ ("x", "d")
                                  , ("~", "g~")
                                  , ("Y", "y")
                                  , ("u", "gu")
                                  , ("U", "gU")
                                  ]
          synonymOp (newName, existingName) =
                    VimOperator newName . operatorApplyToRegionE . fromJust
                    . stringToOperator operators $ existingName

chooseRegisterBinding :: VimBinding
chooseRegisterBinding = mkChooseRegisterBinding $
    \s -> case s of
        (VimState { vsMode = (Visual _) }) -> True
        _ -> False

shiftDBinding :: VimBinding
shiftDBinding = VimBindingE f
    where f "D" (VimState { vsMode = (Visual _) }) = WholeMatch $ do
              (Visual style) <- vsMode <$> getDynamic
              reg <- withBuffer0 regionOfSelectionB
              case style of
                  Block -> withBuffer0 $ do
                      (start, lengths) <- shapeOfBlockRegionB reg
                      moveTo start
                      startCol <- curCol
                      forM_ (reverse [0 .. length lengths - 1]) $ \l -> do
                          moveTo start
                          void $ lineMoveRel l
                          whenM (fmap (== startCol) curCol) deleteToEol
                      leftOnEol
                  _ ->  do
                      reg' <- withBuffer0 $ convertRegionToStyleB reg LineWise
                      reg'' <- withBuffer0 $ mkRegionOfStyleB (regionStart reg')
                                                              (regionEnd reg' -~ Size 1)
                                                              Exclusive
                      void $ operatorApplyToRegionE opDelete 1 $ StyledRegion LineWise reg''
              resetCountE
              switchModeE Normal
              return Finish
          f _ _ = NoMatch

mkOperatorBinding :: VimOperator -> VimBinding
mkOperatorBinding op = VimBindingE f
    where f evs (VimState { vsMode = (Visual _) }) = action <$ evs `matchesString` operatorName op
          f _ _ = NoMatch
          action = do
              (Visual style) <- vsMode <$> getDynamic
              region <- withBuffer0 regionOfSelectionB
              count <- getCountE
              token <- operatorApplyToRegionE op count $ StyledRegion style region
              resetCountE
              clrStatus
              withBuffer0 $ do
                  setVisibleSelection False
                  assign regionStyleA Inclusive
              return token

replaceBinding :: VimBinding
replaceBinding = VimBindingE f
    where f evs (VimState { vsMode = (Visual _) }) =
              case evs of
                "r" -> PartialMatch
                ('r':c:[]) -> WholeMatch $ do
                    (Visual style) <- vsMode <$> getDynamic
                    region <- withBuffer0 regionOfSelectionB
                    withBuffer0 $ transformCharactersInRegionB (StyledRegion style region)
                                      (\x -> if x == '\n' then x else c)
                    switchModeE Normal
                    return Finish
                _ -> NoMatch
          f _ _ = NoMatch

switchEdgeBinding :: VimBinding
switchEdgeBinding = VimBindingE f
    where f [c] (VimState { vsMode = (Visual _) }) | c `elem` "oO"
              = WholeMatch $ do
                  (Visual style) <- vsMode <$> getDynamic
                  withBuffer0 $ do
                      here <- pointB
                      there <- getSelectionMarkPointB
                      (here', there') <- case (c, style) of
                                            ('O', Block) -> flipRectangleB here there
                                            (_, _) -> return (there, here)
                      moveTo here'
                      setSelectionMarkPointB there'
                  return Continue
          f _ _ = NoMatch

insertBinding :: VimBinding
insertBinding = VimBindingE f
    where f evs (VimState { vsMode = (Visual _) }) | evs `elem` group "IA"
            = WholeMatch $ do
                  (Visual style) <- vsMode <$> getDynamic
                  region <- withBuffer0 regionOfSelectionB
                  cursors <- withBuffer0 $ case evs of
                      "I" -> leftEdgesOfRegionB style region
                      "A" -> rightEdgesOfRegionB style region
                      _ -> error "Just silencing ghc's false positive warning."
                  withBuffer0 $ moveTo $ head cursors
                  modifyStateE $ \s -> s { vsSecondaryCursors = drop 1 cursors }
                  switchModeE $ Insert (head evs)
                  return Continue
          f _ _ = NoMatch

textUnderSelection :: BufferM String
textUnderSelection = regionOfSelectionB >>= inclusiveRegionB >>= readRegionB 

gotoFileBinding :: VimBinding
gotoFileBinding = VimBindingY f
    where f "<C-w>" (VimState { vsMode = (Visual _) })  = PartialMatch
          f "<C-w>g" (VimState { vsMode = (Visual _) }) = PartialMatch
          f evs (VimState { vsMode = (Visual _) })
            | evs `elem` ["gf", "<C-w>gf", "<C-w>f"]
            = WholeMatch $ do
                  let editorAction = case evs of
                         "gf"      -> Nothing
                         "<C-w>gf" -> Just newTabE
                         "<C-w>f"  -> Just (splitE >> prevWinE)
                         _         -> error "Just silencing false positive warning."
                  path <- strip <$> (withEditor . withBuffer0 $ textUnderSelection)
                  withEditor escAction
                  gotoFile path editorAction
                  return Drop
          f _ _ = NoMatch
