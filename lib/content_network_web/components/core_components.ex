defmodule ContentNetworkWeb.CoreComponents do
  @moduledoc """
  Provides core UI components for Content Network.
  """
  use Phoenix.Component

  attr :flash, :map, required: true

  def flash_group(assigns) do
    ~H"""
    <div>
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />
    </div>
    """
  end

  attr :kind, :atom, required: true
  attr :flash, :map, required: true

  def flash(assigns) do
    ~H"""
    <div
      :if={msg = Phoenix.Flash.get(@flash, @kind)}
      style={"padding: 12px 16px; margin-bottom: 16px; border-radius: 6px; font-size: 13px; #{flash_style(@kind)}"}
    >
      <%= msg %>
    </div>
    """
  end

  defp flash_style(:info), do: "background: rgba(0, 255, 136, 0.1); border: 1px solid rgba(0, 255, 136, 0.3); color: #00ff88;"
  defp flash_style(:error), do: "background: rgba(255, 68, 68, 0.1); border: 1px solid rgba(255, 68, 68, 0.3); color: #ff4444;"
  defp flash_style(_), do: "background: rgba(136, 136, 136, 0.1); border: 1px solid rgba(136, 136, 136, 0.3); color: #888;"
end
