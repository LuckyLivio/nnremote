namespace LivioRemote.WindowsHost;

internal enum PointerButton { Left, Right }

internal sealed class PointerSession(Func<byte[], bool> position, Func<PointerButton, bool, bool> sendButton)
{
    private bool leftHeld;
    private bool rightHeld;

    public void Apply(byte[] wire)
    {
        byte action = wire[4];
        if (action is 4 or 6)
        {
            // A display change or a rejected position must still let the held button go.
            try { position(wire); }
            finally { SetButton(action == 4 ? PointerButton.Left : PointerButton.Right, down: false); }
            return;
        }
        if (!position(wire)) return;

        switch (action)
        {
            case 1: Click(PointerButton.Left); break;
            case 2: Click(PointerButton.Right); break;
            case 3: SetButton(PointerButton.Left, down: true); break;
            case 5: SetButton(PointerButton.Right, down: true); break;
            case 7:
                Click(PointerButton.Left);
                Click(PointerButton.Left);
                break;
        }
    }

    private void Click(PointerButton button)
    {
        if (SetButton(button, down: true)) SetButton(button, down: false);
    }

    private bool SetButton(PointerButton button, bool down)
    {
        ref bool held = ref (button == PointerButton.Left ? ref leftHeld : ref rightHeld);
        if (held == down || !sendButton(button, down)) return false;
        held = down;
        return true;
    }

    public void ReleaseButtons()
    {
        try { SetButton(PointerButton.Left, down: false); }
        finally { SetButton(PointerButton.Right, down: false); }
    }
}
