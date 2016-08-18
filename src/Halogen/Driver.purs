module Halogen.Driver
  ( Driver
  , runUI
  ) where

import Prelude

import Control.Coroutine (await)
import Control.Coroutine.Stalling (($$?))
import Control.Coroutine.Stalling as SCR
import Control.Monad.Aff (Aff, runAff, forkAff)
import Control.Monad.Aff.AVar (AVar, AVAR, makeVar', putVar, takeVar, modifyVar)
import Control.Monad.Eff (Eff)
import Control.Monad.Eff.Class (liftEff)
import Control.Monad.Eff.Exception (error, throwException)
import Control.Monad.Error.Class (throwError)
import Control.Monad.Free (foldFree)
import Control.Monad.Rec.Class (forever)
import Control.Monad.Trans (lift)
import Control.Plus (empty)

import Data.Map as M
import Data.Maybe (Maybe(..), maybe)
import Data.Lazy (force)

import DOM.HTML.Types (HTMLElement, htmlElementToNode)
import DOM.Node.Node (appendChild)

import Halogen.Component (Component', Component, ComponentSlot(..), ParentDSL, unComponent)
import Halogen.Data.OrdBox (OrdBox, unOrdBox)
import Halogen.Driver.State (DriverState(..), DriverStateX, unDriverStateX, initDriverState)
import Halogen.Effects (HalogenEffects)
import Halogen.HTML.Renderer.VirtualDOM (renderHTML')
import Halogen.Internal.VirtualDOM as V
import Halogen.Query (HalogenF(..))
import Halogen.Query.ChildQuery (unChildQuery)
import Halogen.Query.EventSource (runEventSource)
import Halogen.Query.StateF (StateF(..))

-- | Type alias for driver functions generated by `runUI` - a driver takes an
-- | input of the query algebra (`f`) and returns an `Aff` that returns when
-- | query has been fulfilled.
type Driver f eff = f ~> Aff (HalogenEffects eff)

type DSL s f f' eff p = ParentDSL s f f' (Aff (HalogenEffects eff)) p

-- | This function is the main entry point for a Halogen based UI, taking a root
-- | component, initial state, and HTML element to attach the rendered component
-- | to.
-- |
-- | The returned "driver" function can be used to send actions and requests
-- | into the component hierarchy, allowing the outside world to communicate
-- | with the UI.
runUI
  :: forall f eff
   . Component f (Aff (HalogenEffects eff))
  -> HTMLElement
  -> Aff (HalogenEffects eff) (Driver f eff)
runUI component element = unComponent (runUI' element) component

runUI'
  :: forall s f g eff p
   . HTMLElement
  -> Component' s f g (Aff (HalogenEffects eff)) p
  -> Aff (HalogenEffects eff) (Driver f eff)
runUI' element component = _.driver <$> do
  let node = V.createElement (V.vtext "")
  liftEff $ appendChild (htmlElementToNode node) (htmlElementToNode element)
  initDriverState node component >>=
    unDriverStateX \st -> do
      render st.selfRef
      pure { driver: evalF st.selfRef }

eval
  :: forall s f g eff p
   . AVar (DriverState s f g eff p)
  -> DSL s f g eff p
  ~> Aff (HalogenEffects eff)
eval ref = case _ of
  State i -> do
    case i of
      Get k -> do
        DriverState st <- peekVar ref
        pure (k st.state)
      Modify f next -> do
        modifyVar (\(DriverState st) -> DriverState (st { state = f st.state })) ref
        x <- peekVar ref
        render ref
        pure next
  Subscribe es next -> do
    let consumer = forever (lift <<< evalF ref =<< await)
    forkAff $ SCR.runStallingProcess (runEventSource es $$? consumer)
    pure next
  Lift q -> do
    render ref
    q
  Halt -> empty
  GetSlots k -> do
    DriverState st <- peekVar ref
    pure $ k $ map unOrdBox $ M.keys st.children
  ChildQuery cq ->
    unChildQuery (\p k -> do
      DriverState st <- peekVar ref
      case M.lookup (st.mkOrdBox p) st.children of
        Just dsx -> k (unDriverStateX (\ds q -> evalF ds.selfRef q) dsx)
        Nothing -> throwError (error "Slot lookup failed for child query"))
      cq

evalF
  :: forall s f g eff p
   . AVar (DriverState s f g eff p)
  -> f
  ~> Aff (HalogenEffects eff)
evalF ref q = do
  DriverState st <- peekVar ref
  foldFree (eval ref) (st.component.eval q)

peekVar :: forall eff a. AVar a -> Aff (avar :: AVAR | eff) a
peekVar v = do
  a <- takeVar v
  putVar v a
  pure a

render
  :: forall s f g eff p
   . AVar (DriverState s f g eff p)
  -> Aff (HalogenEffects eff) Unit
render var = do
  DriverState ds <- takeVar var
  children <- makeVar' (M.empty :: M.Map (OrdBox p) (DriverStateX g eff))
  vtree' <-
    renderHTML'
      (handleAff <<< evalF ds.selfRef)
      (renderChild ds.mkOrdBox ds.children children)
      (ds.component.render ds.state)
  node' <- liftEff $ V.patch (V.diff ds.vtree vtree') ds.node
  putVar var $
    DriverState
      { node: node'
      , vtree: vtree'
      , component: ds.component
      , state: ds.state
      , children: ds.children -- TODO
      , mkOrdBox: ds.mkOrdBox
      , selfRef: ds.selfRef
      }

-- TODO: need to setup widgets here properly
renderChild
  :: forall g eff p
   . (p -> OrdBox p)
  -> M.Map (OrdBox p) (DriverStateX g eff)
  -> AVar (M.Map (OrdBox p) (DriverStateX g eff))
  -> ComponentSlot g (Aff (HalogenEffects eff)) p
  -> Aff (HalogenEffects eff) V.VTree
renderChild mkOrdBox children var (ComponentSlot p ctor) =
  case M.lookup (mkOrdBox p) children of
    Just dsx → do
      -- TODO: return the widget for the child
      unDriverStateX (\st -> render st.selfRef) dsx
      pure $ V.vtext ""
    Nothing → pure $ V.vtext ""
  -- dsx <- maybe (initDriverState ?node (force ctor)) pure $ M.lookup (mkOrdBox p) children
  -- pure $ V.vtext ""

-- | TODO: we could do something more intelligent now this isn't baked into the
-- | virtual-dom rendering. Perhaps write to an avar when an error occurs...
-- | something other than a runtime exception anyway.
handleAff
  :: forall eff a
   . Aff (HalogenEffects eff) a
  -> Eff (HalogenEffects eff) Unit
handleAff = void <<< runAff throwException (const (pure unit))
